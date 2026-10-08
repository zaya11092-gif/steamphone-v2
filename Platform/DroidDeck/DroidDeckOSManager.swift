//
// DroidDeck for iOS
// Copyright (C) 2026 DroidDeck-iOS contributors
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import Combine

enum DroidDeckError: LocalizedError {
    case imageMissing

    var errorDescription: String? {
        switch self {
        case .imageMissing:
            return "No SteamPhoneOS image found. Download it first or import one from Files."
        }
    }
}

/// Resumable file downloader built on URLSession's download task API,
/// which supports pause/resume via resume data.
final class DroidDeckImageDownloader: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onFinished: ((URL) -> Void)?
    var onError: ((Error) -> Void)?

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()
    private(set) var task: URLSessionDownloadTask?
    private(set) var resumeData: Data?
    private(set) var isRunning = false

    func start(from url: URL) {
        guard !isRunning else { return }
        let newTask: URLSessionDownloadTask
        if let resumeData {
            newTask = session.downloadTask(withResumeData: resumeData)
        } else {
            newTask = session.downloadTask(with: url)
        }
        resumeData = nil
        task = newTask
        isRunning = true
        newTask.resume()
    }

    /// Pauses the active download, keeping resume data for later continuation.
    func pause() {
        guard let task else { return }
        task.cancel { [weak self] data in
            DispatchQueue.main.async {
                self?.resumeData = data
                self?.task = nil
                self?.isRunning = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        resumeData = nil
        isRunning = false
    }

    func clearResumeData() {
        resumeData = nil
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.onProgress?(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        isRunning = false
        task = nil
        DispatchQueue.main.async {
            self.onFinished?(location)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        isRunning = false
        self.task = nil
        DispatchQueue.main.async {
            self.onError?(error)
        }
    }
}

/// Drives the SteamPhoneOS install pipeline: download the guest disk image,
/// build the VM configuration and register the VM with UTM's data layer.
@MainActor
final class SteamPhoneOSManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(progress: Double)
        case installing
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let downloader = DroidDeckImageDownloader()
    private weak var data: UTMData?

    /// Staging location for the downloaded image, outside any VM bundle.
    private var downloadDestination: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DroidDeckBuildConfig.imageFileName)
    }

    init() {
        downloader.onProgress = { [weak self] fraction in
            self?.phase = .downloading(progress: fraction)
        }
        downloader.onError = { [weak self] error in
            guard let self else { return }
            // A stale resume task fails immediately with an empty file; retry
            // once from scratch before surfacing the error.
            if self.downloader.resumeData != nil {
                self.downloader.clearResumeData()
                self.phase = .idle
                self.startDownload()
                return
            }
            self.phase = .failed("Download failed: \(error.localizedDescription)")
        }
        downloader.onFinished = { [weak self] tmpURL in
            self?.stageDownloadedFile(at: tmpURL)
        }
    }

    // MARK: - State

    /// The registered SteamPhoneOS VM, if it exists already.
    var existingVM: VMData? {
        guard let data else { return nil }
        return data.virtualMachines.first {
            !$0.isShortcut && $0.config?.information.name == DroidDeckBuildConfig.vmName
        }
    }

    var hasStagedImage: Bool {
        FileManager.default.fileExists(atPath: downloadDestination.path)
    }

    var canResumeDownload: Bool {
        downloader.resumeData != nil
    }

    func refreshPhase() {
        guard let data else { return }
        if case .downloading = phase { return } // do not disturb an active download
        if data.virtualMachines.contains(where: {
            !$0.isShortcut && $0.config?.information.name == DroidDeckBuildConfig.vmName
        }) {
            phase = .ready
        } else {
            phase = .idle
        }
    }

    func attach(data: UTMData) {
        self.data = data
        refreshPhase()
    }

    // MARK: - Download & install

    func startDownload() {
        guard !downloader.isRunning else { return }
        if hasStagedImage {
            try? FileManager.default.removeItem(at: downloadDestination)
        }
        downloader.start(from: DroidDeckBuildConfig.imageDownloadURL)
        phase = .downloading(progress: 0)
    }

    func pauseDownload() {
        downloader.pause()
        phase = .idle
    }

    func cancelDownload() {
        downloader.cancel()
        phase = .idle
    }

    private func stageDownloadedFile(at tmpURL: URL) {
        do {
            // URLSession happily "completes" a 404/error page; reject anything
            // implausibly small for a multi-GB disk image before staging it.
            let minPlausibleSize: Int64 = 100 * 1024 * 1024
            let downloadedSize = (try? FileManager.default.attributesOfItem(atPath: tmpURL.path)[.size] as? Int64) ?? 0
            if downloadedSize < minPlausibleSize {
                try? FileManager.default.removeItem(at: tmpURL)
                phase = .failed("The server did not return the SteamPhoneOS image (got only \(downloadedSize / 1_000_000) MB). The image may not be published yet — use \"Import image from Files\" or update the app.")
                return
            }
            // iOS does not pre-create Application Support.
            let supportDir = downloadDestination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: downloadDestination)
            try FileManager.default.moveItem(at: tmpURL, to: downloadDestination)
            guard let data else { return }
            Task { @MainActor in
                do {
                    try await installImage(at: nil, into: data)
                } catch {
                    phase = .failed("Install failed: \(error.localizedDescription)")
                }
            }
        } catch {
            phase = .failed("Could not store image: \(error.localizedDescription)")
        }
    }

    /// Imports a local qcow2 into a fresh SteamPhoneOS VM. Used both after the
    /// download finishes and by the Files-app import path.
    func installImage(at url: URL?, into data: UTMData) async throws {
        let sourceURL: URL
        if let url, url.isFileURL {
            sourceURL = url
        } else if hasStagedImage {
            sourceURL = downloadDestination
        } else {
            throw DroidDeckError.imageMissing
        }
        let needsSecurityScope = url?.startAccessingSecurityScopedResource() ?? false
        defer {
            if needsSecurityScope {
                url?.stopAccessingSecurityScopedResource()
            }
        }
        phase = .installing
        // Replace any stale VM from an interrupted earlier install.
        if let oldVM = existingVM {
            try? await data.delete(vm: oldVM)
        }
        do {
            let config = DroidDeckVMBuilder.makeConfiguration(imageURL: sourceURL)
            _ = try await data.create(config: config)
            // The image was copied into the .utm bundle; drop the staged copy.
            if sourceURL == downloadDestination {
                try? FileManager.default.removeItem(at: downloadDestination)
            }
            phase = .ready
        } catch {
            phase = .failed("Install failed: \(error.localizedDescription)")
            throw error
        }
    }

    func deleteVM() async throws {
        guard let data, let vm = existingVM else { return }
        try await data.delete(vm: vm)
        phase = .idle
    }
}

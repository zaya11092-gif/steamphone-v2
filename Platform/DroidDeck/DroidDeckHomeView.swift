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

import SwiftUI
import UniformTypeIdentifiers

/// DroidDeck home screen: a Deck-style launcher with the local DroidDeckOS
/// virtual machine as the hero card and PC streaming as the fast lane.
struct DroidDeckHomeView: View {
    @EnvironmentObject private var data: UTMData
    @StateObject private var manager = DroidDeckOSManager()
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var showStreaming = false
    @State private var showGPUBridge = false
    @State private var showImportPicker = false
    @State private var installError: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    droidDeckOSCard
                    streamingCard
                    if !DroidDeckHardware.isDeviceSupported {
                        unsupportedWarning
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(droidDeckBackground.ignoresSafeArea())
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .onAppear {
            manager.attach(data: data)
        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.diskImage]) { result in
            switch result {
            case .success(let url):
                Task { @MainActor in
                    do {
                        try await manager.installImage(at: url, into: data)
                    } catch {
                        installError = error.localizedDescription
                    }
                }
            case .failure(let error):
                installError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showSettings) {
            DroidDeckSettingsView(manager: manager)
        }
        .sheet(isPresented: $showAbout) {
            DroidDeckAboutView()
        }
        .sheet(isPresented: $showStreaming) {
            MoonlightSessionView()
        }
        .sheet(isPresented: $showGPUBridge) {
            GPUBridgeDiagnosticsView()
        }
        .alert("SteamPhoneOS", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(installError ?? "")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 6) {
            Text("SteamPhone")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing)
                )
            Text("SteamOS-style gaming on iPhone")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private var droidDeckOSCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SteamPhoneOS").font(.title2.bold())
                    Text(statusSubtitle).font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                settingsMenu
            }
            switch manager.phase {
            case .idle:
                VStack(spacing: 10) {
                    BigActionButton(title: manager.hasStagedImage ? "Install SteamPhoneOS" : "Download SteamPhoneOS (~4 GB)") {
                        if manager.hasStagedImage {
                            Task { @MainActor in
                                do { try await manager.installImage(at: nil, into: data) }
                                catch { installError = error.localizedDescription }
                            }
                        } else {
                            manager.startDownload()
                        }
                    }
                    Button {
                        showImportPicker = true
                    } label: {
                        Label("Import image from Files", systemImage: "square.and.arrow.down")
                            .font(.subheadline)
                    }
                }
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text("Downloading… \(Int(progress * 100))%")
                        .font(.subheadline)
                }
                HStack {
                    BigActionButton(title: "Pause", prominent: false) {
                        manager.pauseDownload()
                    }
                    BigActionButton(title: "Cancel", prominent: false) {
                        manager.cancelDownload()
                    }
                }
            case .installing:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Importing image into virtual machine…")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            case .ready:
                BigActionButton(title: "Boot SteamPhoneOS") {
                    bootDroidDeckOS()
                }
            case .failed(let message):
                VStack(spacing: 10) {
                    Text(message).font(.subheadline).foregroundColor(.red)
                    BigActionButton(title: "Retry") {
                        manager.startDownload()
                    }
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08)))
    }

    private var streamingCard: some View {
        Button {
            showStreaming = true
        } label: {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 30))
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stream from your PC").font(.headline)
                    Text("Full-speed Steam gaming via GameStream (Sunshine/Moonlight)")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.secondary)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private var unsupportedWarning: some View {
        Label(
            "This device has less than 6 GB of RAM. SteamPhoneOS may be killed by the system while running.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.subheadline)
        .foregroundColor(.orange)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(.orange.opacity(0.12)))
    }

    private var settingsMenu: some View {
        Menu {
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            Button {
                showAbout = true
            } label: {
                Label("About & Licenses", systemImage: "info.circle")
            }
            Button {
                showGPUBridge = true
            } label: {
                Label("GPU Bridge diagnostics (G1)", systemImage: "speedometer")
            }
            Button(role: .destructive) {
                Task { @MainActor in
                    try? await manager.deleteVM()
                }
            } label: {
                Label("Delete SteamPhoneOS VM", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
        }
    }

    private var statusSubtitle: String {
        switch manager.phase {
        case .idle: return "ARM64 Linux + FEX + Steam · QEMU \(Main.jitAvailable ? "JIT" : "interpreter (SE)")"
        case .downloading: return "Fetching guest image"
        case .installing: return "Creating virtual machine"
        case .ready: return "\(DroidDeckHardware.recommendedMemoryMib / 1024) GB RAM · \(DroidDeckHardware.recommendedCpuCount) vCPU · Ready"
        case .failed: return "Attention required"
        }
    }

    // MARK: - Actions

    private func bootDroidDeckOS() {
        guard let vm = manager.existingVM else {
            installError = "DroidDeckOS VM is missing. Reinstall the image."
            return
        }
        data.run(vm: vm)
    }
}

// MARK: - Style helpers

private extension Color {
    static let droidDeckBackground = Color(red: 0.05, green: 0.07, blue: 0.12)
    static let cardBackground = Color(red: 0.10, green: 0.13, blue: 0.20)
}

/// Deck-style oversized button.
struct BigActionButton: View {
    let title: LocalizedStringKey
    var prominent: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(prominent ? AnyShapeStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                                        : AnyShapeStyle(Color.secondary.opacity(0.25)))
                )
                .foregroundColor(prominent ? .black : .primary)
        }
        .buttonStyle(.plain)
    }
}

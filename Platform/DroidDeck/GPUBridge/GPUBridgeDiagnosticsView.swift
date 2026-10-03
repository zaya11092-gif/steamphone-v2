//
// SteamPhone GPU Bridge (SPGB)
// Copyright (C) 2026 steamphone-v2 contributors
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
import MetalKit

/// On-device gate-G1 harness: runs the SPGB guest simulator's byte stream
/// through the Metal host renderer and reports live results.
///
/// Passing this screen proves the Metal side of the QEMU→Metal translator
/// executes the frozen wire protocol — the precondition for the G2 wiring
/// into QEMU's virtio-gpu backend.
struct GPUBridgeDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = GPUBridgeDiagnosticsModel()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if model.initialized {
                        GPUBridgeMetalView(model: model)
                            .frame(height: 320)
                            .cornerRadius(16)
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
                    } else {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black.opacity(0.5))
                            .frame(height: 320)
                            .overlay(
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle")
                                    Text(model.failure ?? "Initializing Metal…")
                                        .font(.footnote)
                                        .multilineTextAlignment(.center)
                                }
                                .padding()
                            )
                    }

                    statsSection
                    checklistSection
                    vulkanSection
                    contextSection
                }
                .padding()
            }
            .navigationTitle("GPU Bridge (G1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        model.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.toggleRunning()
                    } label: {
                        Text(model.isRunning ? "Pause" : "Run")
                    }
                }
            }
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live statistics").font(.headline)
            HStack {
                stat("FPS", value: String(format: "%.1f", model.fps))
                stat("Quads/frame", value: "\(model.quadsPerFrame)")
                stat("Frames", value: "\(model.framesPresented)")
            }
            HStack {
                stat("Uploads", value: byteFormatter.string(fromByteCount: Int64(model.bytesUploaded)))
                stat("Commands", value: "\(model.commandsExecuted)")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gate checklist").font(.headline)
            checklistRow("Metal device created", passed: model.checklist.deviceCreated)
            checklistRow("Shaders compiled & pipelines built", passed: model.checklist.pipelinesBuilt)
            checklistRow("Resources allocated (target + texture)", passed: model.checklist.resourcesCreated)
            checklistRow("Pixel upload executed", passed: model.checklist.transferExecuted)
            checklistRow("Draw commands executed", passed: model.checklist.quadsDrawn)
            checklistRow("Frame presented to display", passed: model.checklist.framePresented)
            checklistRow("Sustained ≥ 30 FPS", passed: model.checklist.sustainedFPS)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private var contextSection: some View {
        Text("This harness runs the SPGB wire protocol (the contract QEMU's virtio-gpu backend will speak) entirely on Metal, in-process — the G1 gate from gpu-rd/G0-audit.md. G2 wires the same execute() path behind QEMU; G3 sets the performance bar. Local VM gaming stays software-rendered until G2/G3 pass.")
            .font(.footnote)
            .foregroundColor(.secondary)
            .padding()
    }

    private var vulkanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vulkan via MoltenVK (3D track, WP1)").font(.headline)
            if SPGBVulkanProbe.isAvailable {
                HStack {
                    Button {
                        model.runVulkanProbe()
                    } label: {
                        Label("Run probe", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Image(systemName: model.vulkanProbePassed ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundColor(model.vulkanProbePassed ? .green : .secondary)
                }
                if let summary = model.vulkanSummary {
                    Text(summary)
                        .font(.footnote.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text("MoltenVK not linked into this build. Build the MoltenVK profile to activate the probe (gpu-rd/moltenvk/README.md).")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private func stat(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.title3.monospacedDigit().bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checklistRow(_ label: LocalizedStringKey, passed: Bool) -> some View {
        HStack {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundColor(passed ? .green : .secondary)
            Text(label).font(.subheadline)
            Spacer()
        }
    }

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }
}

// MARK: - Model

@MainActor
final class GPUBridgeDiagnosticsModel: NSObject, ObservableObject {
    struct Checklist {
        var deviceCreated = false
        var pipelinesBuilt = false
        var resourcesCreated = false
        var transferExecuted = false
        var quadsDrawn = false
        var framePresented = false
        var sustainedFPS = false
    }

    @Published var initialized = false
    @Published var failure: String?
    @Published var isRunning = true
    @Published var fps: Double = 0
    @Published var framesPresented: UInt64 = 0
    @Published var bytesUploaded: UInt64 = 0
    @Published var commandsExecuted: UInt64 = 0
    @Published var checklist = Checklist()
    @Published var vulkanSummary: String?
    @Published var vulkanProbePassed = false

    let quadsPerFrame = 64
    private(set) var renderer: SPGBHostRenderer?
    private let simulator: SPGBGuestSimulator

    // FPS accounting
    private var frameTimestamps: [CFTimeInterval] = []

    override init() {
        simulator = SPGBGuestSimulator(frame: .init(quadsPerFrame: quadsPerFrame,
                                                    targetSize: CGSize(width: 1280, height: 720),
                                                    textureSize: 256))
        super.init()
        do {
            let renderer = try SPGBHostRenderer()
            self.renderer = renderer
            checklist.deviceCreated = true
            initialized = true
        } catch {
            failure = error.localizedDescription
        }
    }

    func stop() {
        isRunning = false
    }

    func toggleRunning() {
        isRunning.toggle()
    }

    func runVulkanProbe() {
        guard SPGBVulkanProbe.isAvailable else {
            vulkanSummary = "Vulkan module not available in this build."
            return
        }
        do {
            let result = try SPGBVulkanProbe.run()
            vulkanProbePassed = true
            vulkanSummary = """
            device: \(result.deviceName)
            Vulkan: \(result.apiVersion)   driver: \(result.driverVersion)
            queue families: \(result.queueFamilyCount)   memory types: \(result.memoryTypeCount)
            graphics queue: \(result.graphicsQueue ? "yes" : "no")
            """
        } catch {
            vulkanProbePassed = false
            vulkanSummary = "probe failed: \(error.localizedDescription)"
        }
    }

    /// Called by GPUBridgeMetalView on every vsync tick.
    func renderFrame(drawable: any MTLDrawable) {
        guard isRunning, let renderer, initialized else { return }
        renderer.currentDrawable = drawable
        do {
            let stream = simulator.nextFrameStream()
            commandsExecuted &+= UInt64(try renderer.execute(stream: stream))
            let stats = renderer.statistics
            framesPresented = stats.framesPresented
            bytesUploaded = stats.bytesUploaded
            withAnimation {
                checklist.resourcesCreated = true
                checklist.transferExecuted = stats.bytesUploaded > 0
                checklist.quadsDrawn = stats.quadsDrawn > 0
                checklist.framePresented = stats.framesPresented > 0
            }
            recordFPS()
        } catch {
            failure = error.localizedDescription
            isRunning = false
        }
    }

    private func recordFPS() {
        let now = CACurrentMediaTime()
        frameTimestamps.append(now)
        // Keep a one-second window.
        while let first = frameTimestamps.first, now - first > 1.0 {
            frameTimestamps.removeFirst()
        }
        let measured = Double(frameTimestamps.count)
        fps = measured
        if measured >= 30 {
            checklist.sustainedFPS = true
        }
    }
}

// MARK: - MetalKit view

/// Draws the harness at display refresh. The view itself renders nothing —
/// the SPGB renderer owns all encoders; this view supplies the drawable.
final class GPUBridgeMetalView: MTKView {
    private weak var diagnosticsModel: GPUBridgeDiagnosticsModel?

    init(model: GPUBridgeDiagnosticsModel) {
        super.init(frame: .zero, device: model.renderer?.device)
        diagnosticsModel = model
        backgroundColor = .black
        isPaused = false
        enableSetNeedsDisplay = false
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

extension GPUBridgeMetalView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable else { return }
        diagnosticsModel?.renderFrame(drawable: drawable)
    }
}

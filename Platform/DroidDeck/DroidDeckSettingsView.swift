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

/// Resource tuning and image management for the SteamPhoneOS VM.
struct DroidDeckSettingsView: View {
    @EnvironmentObject private var data: UTMData
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: SteamPhoneOSManager
    @State private var memoryMib: Int = DroidDeckHardware.recommendedMemoryMib
    @State private var cpuCount: Int = DroidDeckHardware.recommendedCpuCount
    @State private var saveError: String?

    private var vm: VMData? {
        manager.existingVM
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("Device")
                        Spacer()
                        Text(DroidDeckHardware.deviceSummary)
                            .foregroundColor(.secondary)
                            .font(.footnote)
                    }
                } header: {
                    Text("Hardware")
                } footer: {
                    Text("iOS reserves roughly 2 GB for itself; assigning more than recommended risks the VM being killed by the system.")
                }
                if let vm {
                    Section("SteamPhoneOS virtual machine") {
                        Stepper(value: $memoryMib, in: 1024...6144, step: 512) {
                            HStack {
                                Text("Memory")
                                Spacer()
                                Text("\(memoryMib / 1024) GB").foregroundColor(.secondary)
                            }
                        }
                        Stepper(value: $cpuCount, in: 1...8) {
                            HStack {
                                Text("vCPU cores")
                                Spacer()
                                Text("\(cpuCount)").foregroundColor(.secondary)
                            }
                        }
                        Button("Apply changes") {
                            applyChanges(vm: vm)
                        }
                    }
                } else {
                    Section {
                        Text("No SteamPhoneOS VM installed yet.")
                            .foregroundColor(.secondary)
                    }
                }
                Section("Guest image") {
                    LabeledRow(label: "Image version", value: DroidDeckBuildConfig.imageVersion)
                    LabeledRow(label: "Download URL", value: DroidDeckBuildConfig.imageDownloadURL.absoluteString)
                }
                Section {
                    Toggle(isOn: .init(
                        get: { UserDefaults.standard.bool(forKey: "DroidDeckUseRutabagaGPU") },
                        set: { UserDefaults.standard.set($0, forKey: "DroidDeckUseRutabagaGPU") }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Experimental GPU bridge (rutabaga)")
                            Text("Only for SteamPhone-3D engine builds; ignored elsewhere.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("3D acceleration")
                } footer: {
                    Text("Applies on the next VM install. Requires an engine build with virtio-gpu-rutabaga compiled in.")
                }
                if let saveError {
                    Section {
                        Text(saveError).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func applyChanges(vm: VMData) {
        guard let config = vm.config as? UTMQemuConfiguration else {
            saveError = "VM configuration is not QEMU-based."
            return
        }
        Task { @MainActor in
            do {
                config.system.memorySize = memoryMib
                config.system.cpuCount = cpuCount
                try await data.save(vm: vm)
                saveError = nil
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

private struct LabeledRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            Text(value)
                .font(.footnote)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

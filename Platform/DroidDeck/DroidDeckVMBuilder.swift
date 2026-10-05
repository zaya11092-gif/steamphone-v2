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

/// Builds the QEMU configuration for the DroidDeckOS guest VM.
///
/// The guest is an ARM64 Linux system (same architecture as the host, which
/// makes QEMU's TCG translation many times cheaper than cross-arch x86
/// emulation) booting via UEFI from a single virtio disk. This mirrors the
/// recipe the Android DroidDeck project uses inside its proot runtime:
/// ARM64 userland + FEX-EMU for x86_64 Steam/game binaries.
enum DroidDeckVMBuilder {
    /// Creates a configuration rooted at the given disk image.
    ///
    /// - Parameter imageURL: qcow2 disk image to attach as the boot drive.
    ///   `UTMData.create(config:)` imports the file into the .utm bundle.
    /// MainActor: UTMQemuConfiguration is main-actor isolated.
    @MainActor
    static func makeConfiguration(imageURL: URL) -> UTMQemuConfiguration {
        let config = UTMQemuConfiguration()
        config.information.name = DroidDeckBuildConfig.vmName
        config.information.notes = "SteamOS-like ARM64 environment (Linux + FEX + Steam)"

        config.system.architecture = .aarch64
        config.system.target = QEMUTarget_aarch64.virt
        config.reset(forArchitecture: config.system.architecture, target: config.system.target)

        config.system.memorySize = DroidDeckHardware.recommendedMemoryMib
        config.system.cpuCount = DroidDeckHardware.recommendedCpuCount

        // No hypervisor on iOS: everything runs through TCG. The JIT edition
        // translates at full speed; the SE edition interprets.
        config.qemu.hasHypervisor = false
        // DroidDeckOS images are GPT + ESP, booted through QEMU_EFI.
        config.qemu.hasUefiBoot = true
        config.qemu.hasTPMDevice = false
        config.qemu.hasPreloadedSecureBootKeys = false

        // virtio-gpu (2D only; there is no host GPU acceleration on iOS).
        // Follow the wizard's pattern of checking the constant exists for the
        // target before assigning, so an engine update cannot break the build.
        if !config.displays.isEmpty {
            let newCard = "virtio-gpu-pci"
            if config.system.architecture.displayDeviceType.allRawValues.contains(where: { $0 == newCard }) {
                config.displays[0].hardware = AnyQEMUConstant(rawValue: newCard)!
            }
        }

        // 3D track (gpu-rd/3d-plan.md): when the engine build has the
        // rutabaga device compiled in, a debug toggle swaps the display for
        // virtio-gpu-rutabaga. Requires a SteamPhone-3D build; the shipped
        // QEMU silently errors on an unknown device otherwise, so this stays
        // opt-in via UserDefaults.
        if UserDefaults.standard.bool(forKey: "DroidDeckUseRutabagaGPU") {
            config.qemu.additionalArguments.append(QEMUArgument("-device"))
            config.qemu.additionalArguments.append(QEMUArgument("virtio-gpu-rutabaga-pci"))
        }

        // Boot drive with the downloaded image.
        var drive = UTMQemuConfigurationDrive(forArchitecture: .aarch64, target: QEMUTarget_aarch64.virt)
        drive.imageURL = imageURL
        config.drives.append(drive)

        // Networking, sound and input keep the architecture defaults that
        // reset(forArchitecture:target:) selected (virtio-net user backend,
        // default sound device, USB tablet + keyboard).
        return config
    }
}

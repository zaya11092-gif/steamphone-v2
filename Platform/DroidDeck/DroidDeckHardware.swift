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

/// Device capability tiers used to size the DroidDeckOS virtual machine.
///
/// iOS grants each app only a fraction of physical RAM before Jetsam kills it
/// (UTM requests the increased-memory entitlement; even then ~1.5-2 GB stays
/// reserved for the system). The tiers below stay on the safe side.
enum DroidDeckHardware {
    /// Physical RAM in gigabytes (SI units, as reported by physicalMemory).
    static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000
    }

    /// Devices below this tier cannot reasonably run the guest.
    static var isDeviceSupported: Bool {
        physicalMemoryGB >= 5.0
    }

    /// Recommended guest memory in MiB, clamped by physical RAM tier.
    static var recommendedMemoryMib: Int {
        let gb = physicalMemoryGB
        if gb >= 8.0 { return 5120 }
        if gb >= 6.0 { return 4096 }
        if gb >= 5.0 { return 3072 }
        return 2048 // unsupported tier; let the user try anyway
    }

    /// Recommended guest vCPU count. QEMU TCG scales poorly past a few threads.
    static var recommendedCpuCount: Int {
        max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// Human-readable summary shown in Settings.
    static var deviceSummary: String {
        let mem = String(format: "%.1f GB RAM", physicalMemoryGB)
        let cpu = "\(ProcessInfo.processInfo.activeProcessorCount) cores"
        let jit = Main.jitAvailable ? "JIT enabled" : "JIT unavailable (interpreter)"
        return "\(mem), \(cpu), \(jit)"
    }
}

/// Build-time configuration knobs for the SteamPhoneOS guest image.
enum DroidDeckBuildConfig {
    /// Name of the VM as it appears inside the UTM registry.
    static let vmName = "SteamPhoneOS"

    /// Version of the guest image this build of the app expects.
    /// Bump when the QEMU arguments or image layout change incompatibly.
    static let imageVersion = "0.2.0"

    /// File name used for the downloaded (uncompressed) disk image.
    static let imageFileName = "SteamPhoneOS-\(imageVersion).qcow2"

    /// Where the guest image is downloaded from. Points at this project's
    /// GitHub release; overridable for testing via UserDefaults key
    /// "DroidDeckImageURL" (e.g. pointing at a CI artifact).
    static var imageDownloadURL: URL {
        let fallback = "https://github.com/zaya11092-gif/steamphone-v2/releases/download/v\(imageVersion)/SteamPhoneOS-\(imageVersion)-arm64.qcow2"
        if let override = UserDefaults.standard.string(forKey: "DroidDeckImageURL"), let url = URL(string: override) {
            return url
        }
        return URL(string: fallback)!
    }
}

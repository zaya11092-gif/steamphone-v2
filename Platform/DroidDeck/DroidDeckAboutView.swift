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

/// Attribution and honest expectations, as required by the GPL and by reality.
struct DroidDeckAboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("What is this?",
                            "An unofficial iOS port of the DroidDeck concept: a SteamOS-style gaming environment. The Android original runs an ARM64 Linux runtime through proot with FEX-EMU and host GPU thunks; iOS forbids that architecture, so here Steam runs inside a fully emulated ARM64 Linux virtual machine (QEMU).")
                    section("Performance expectations",
                            "• Streaming mode: full speed — modern games are playable this way.\n• Local JIT edition: Steam interface usable but slow; lightweight and 2D games are marginal.\n• Local SE edition: significantly slower (interpreter-based emulation).\n• Local 3D rendering is software-only (no GPU acceleration exists for QEMU on iOS today); see the gpu-rd track in the source repository for the ongoing paravirtual GPU research.")
                    section("Credits & licenses",
                            "DroidDeck for iOS is GPL-3.0 licensed and builds on:\n\n• UTM (Apache-2.0) — virtual machine UI and engine integration\n• QEMU (GPLv2) via utmapp/QEMU — full-system emulation\n• moonlight-common-c (GPL-3.0) — GameStream streaming protocol\n• Droid-Deck/DroidDeck (GPL-3.0) — the original Android project and its FEX runtime recipe\n• Valve's Steam client runs unmodified inside the guest")
                    section("Trademarks",
                            "Steam and SteamOS are trademarks of Valve Corporation. This project is not affiliated with or endorsed by Valve. Not affiliated with the Droid-Deck organization either — just a port of their idea.")
                }
                .padding()
            }
            .navigationTitle("About & Licenses")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func section(_ title: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

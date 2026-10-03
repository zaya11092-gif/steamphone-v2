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

import Foundation

/// Generates SPGB command streams the way a guest Mesa paravirt driver
/// (virgl/gfxstream-style) would: create resources, upload pixel data,
/// bind a render target, clear, draw textured quads, present, submit.
///
/// This is the G1 "simulated guest": identical byte-level output to what
/// the G2 QEMU backend will forward, minus the virtio framing.
final class SPGBGuestSimulator {
    struct FrameDescription {
        var quadsPerFrame: Int
        var targetSize: CGSize
        var textureSize: Int
    }

    let frame: FrameDescription
    private var frameIndex: UInt64 = 0
    private var resourcesCreated = false

    /// Resource ids used by the simulated guest.
    private static let targetResourceId: UInt32 = 1
    private static let textureResourceId: UInt32 = 2

    init(frame: FrameDescription = FrameDescription(quadsPerFrame: 64,
                                                    targetSize: CGSize(width: 1280, height: 720),
                                                    textureSize: 256)) {
        self.frame = frame
    }

    /// Builds the byte stream for the next frame.
    func nextFrameStream() -> Data {
        SPGBStreamEncoder.encode(nextFrameCommands())
    }

    func nextFrameCommands() -> [SPGBCommand] {
        var commands: [SPGBCommand] = []
        frameIndex &+= 1

        // Session setup, as a guest driver does on context init.
        if !resourcesCreated {
            commands.append(SPGBStreamEncoder.resourceCreate(SPGBResourceCreate(
                id: Self.targetResourceId,
                width: UInt32(frame.targetSize.width),
                height: UInt32(frame.targetSize.height),
                format: .rgba8Unorm)))
            commands.append(SPGBStreamEncoder.resourceCreate(SPGBResourceCreate(
                id: Self.textureResourceId,
                width: UInt32(frame.textureSize),
                height: UInt32(frame.textureSize),
                format: .rgba8Unorm)))
            commands.append(SPGBStreamEncoder.transfer2D(SPGBTransfer2D(
                id: Self.textureResourceId,
                x: 0, y: 0,
                w: UInt32(frame.textureSize), h: UInt32(frame.textureSize),
                stride: UInt32(frame.textureSize),
                pixels: Self.proceduralTexture(size: frame.textureSize))))
            resourcesCreated = true
        }

        // Per-frame: target -> clear -> quads -> present -> submit.
        commands.append(SPGBStreamEncoder.setTarget(SPGBSetTarget(id: Self.targetResourceId)))

        let phase = Float(frameIndex % 240) / 240.0
        commands.append(SPGBStreamEncoder.clear(SPGBClear(r: 0.05 + 0.03 * phase,
                                                          g: 0.07,
                                                          b: 0.12,
                                                          a: 1.0)))
        commands.append(SPGBStreamEncoder.setTexture(SPGBSetTexture(slot: 0, id: Self.textureResourceId)))

        let tw = Float(frame.targetSize.width)
        let th = Float(frame.targetSize.height)
        let cols = 8
        let rows = (frame.quadsPerFrame + cols - 1) / cols
        let cellW = tw / Float(cols)
        let cellH = th / Float(rows)
        for i in 0..<frame.quadsPerFrame {
            let col = i % cols
            let row = i / cols
            let wobble = sin(Double(phase * 2.0 * .pi + Double(i) * 0.35))
            let inset = 8.0 + CGFloat(10.0 + 6.0 * wobble)
            let x = Float(CGFloat(col) * cellW + inset)
            let y = Float(CGFloat(row) * cellH + inset)
            let w = cellW - Float(inset) * 2
            let h = cellH - Float(inset) * 2
            commands.append(SPGBStreamEncoder.drawQuad(SPGBDrawQuad(
                x: x, y: y, w: max(w, 4), h: max(h, 4),
                u0: 0, v0: 0, u1: 1, v1: 1,
                alpha: 1.0)))
        }

        commands.append(SPGBStreamEncoder.present(SPGBPresent(targetId: Self.targetResourceId)))
        commands.append(SPGBStreamEncoder.submit())
        return commands
    }

    /// RGBA8 checkerboard with a color ramp — exercises real pixel upload.
    private static func proceduralTexture(size: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let offset = (y * size + x) * 4
                let checker = ((x / 16) ^ (y / 16)) & 1
                pixels[offset + 0] = UInt8(checker == 1 ? 220 : 40)                       // R
                pixels[offset + 1] = UInt8((x * 255) / max(size - 1, 1))                  // G
                pixels[offset + 2] = UInt8((y * 255) / max(size - 1, 1))                  // B
                pixels[offset + 3] = 255                                                  // A
            }
        }
        return pixels
    }
}

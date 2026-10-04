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
import Metal
import QuartzCore

/// From SPGBProtocol.h (kept in sync manually for the Swift side).
let SPGB_MAX_TEXTURES = 8

/// The Metal side of the QEMU→Metal translator (gate G1).
///
/// Executes SPGB command streams against Metal: resources become MTLTextures,
/// TRANSFER_2D becomes bytes→texture replaces, DRAW_QUAD becomes a textured
/// triangle-strip render, PRESENT composites the target into the drawable.
/// In gate G2 the same execute() entry runs behind QEMU's virtio-gpu backend
/// through a thin C ABI; the translation logic below does not change.
final class SPGBHostRenderer {
    struct Statistics {
        var framesPresented: UInt64 = 0
        var quadsDrawn: UInt64 = 0
        var bytesUploaded: UInt64 = 0
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var samplerState: MTLSamplerState?
    private var resources: [UInt32: MTLTexture] = [:]
    private var target: MTLTexture?
    private var boundTextures: [MTLTexture?] = .init(repeating: nil, count: SPGB_MAX_TEXTURES)
    private(set) var statistics = Statistics()

    /// Set by the harness view each frame; PRESENT composites into it.
    var currentDrawable: (any MTLDrawable)?

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct SPGBVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex SPGBVertexOut spgb_vertex(uint vid [[vertex_id]],
                                     constant float4 *rect [[buffer(0)]]) {
        // rect[0] = (x0, y0, x1, y1) in clip space; 4 vertices, triangle strip.
        constant float2 corners[4] = { float2(0.0, 0.0), float2(1.0, 0.0),
                                       float2(0.0, 1.0), float2(1.0, 1.0) };
        float2 c = corners[vid];
        float2 xy = mix(rect[0].xy, rect[0].zw, c);
        SPGBVertexOut out;
        out.position = float4(xy, 0.0, 1.0);
        out.uv = c;
        return out;
    }

    fragment float4 spgb_fragment(SPGBVertexOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  sampler samp [[sampler(0)]],
                                  constant float4 &uvrect [[buffer(0)]]) {
        float2 uv = mix(uvrect.xy, uvrect.zw, in.uv);
        return tex.sample(samp, uv);
    }
    """

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SPGBError.metalUnavailable
        }
        guard let queue = device.makeCommandQueue() else {
            throw SPGBError.pipelineFailure("command queue")
        }
        self.device = device
        self.queue = queue

        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: sampler)
    }

    /// Pipeline states are per render-target pixel format (targets can be
    /// RGBA8 while the drawable is the layer's BGRA8).
    private func pipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let cached = pipelines[format] {
            return cached
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw SPGBError.pipelineFailure("library: \(error.localizedDescription)")
        }
        guard let vertexFn = library.makeFunction(name: "spgb_vertex"),
              let fragmentFn = library.makeFunction(name: "spgb_fragment") else {
            throw SPGBError.pipelineFailure("shader functions not found")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = format
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[format] = state
        return state
    }

    // MARK: - Command execution

    /// Executes a raw SPGB byte stream (the exact format QEMU will emit).
    /// Returns the number of commands processed.
    @discardableResult
    func execute(stream: Data) throws -> Int {
        let commands = try SPGBStreamDecoder.decode(stream)
        try execute(commands: commands)
        return commands.count
    }

    func execute(commands: [SPGBCommand]) throws {
        for command in commands {
            try execute(command)
        }
    }

    private func execute(_ command: SPGBCommand) throws {
        switch command.opcode {
        case .nop, .submit:
            break // batching is implicit: encoders commit as they are built

        case .resourceCreate:
            guard let r = command.resourceCreate else { throw SPGBError.truncatedPayload }
            let format: MTLPixelFormat
            switch r.format {
            case .rgba8Unorm: format = .rgba8Unorm
            case .bgra8Unorm: format = .bgra8Unorm
            case .invalid: throw SPGBError.pipelineFailure("invalid resource format")
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                      width: Int(r.width),
                                                                      height: Int(r.height),
                                                                      mipmapped: false)
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .private
            resources[r.id] = device.makeTexture(descriptor: descriptor)

        case .resourceDestroy:
            guard let r = command.resourceDestroyPayload else { throw SPGBError.truncatedPayload }
            resources.removeValue(forKey: r)
            for slot in 0..<SPGB_MAX_TEXTURES {
                boundTextures[slot] = nil
            }

        case .transfer2D:
            guard let header = command.transfer2DHeader, let pixels = command.pixelPayload else {
                throw SPGBError.truncatedPayload
            }
            guard let texture = resources[header.id] else { throw SPGBError.missingResource(header.id) }
            try upload(pixels: pixels, to: texture, region: header)
            statistics.bytesUploaded &+= UInt64(pixels.count)

        case .setTarget:
            guard let s = command.setTarget else { throw SPGBError.truncatedPayload }
            guard let texture = resources[s.id] else { throw SPGBError.missingResource(s.id) }
            target = texture

        case .clear:
            guard let c = command.clear else { throw SPGBError.truncatedPayload }
            try clear(color: c)

        case .setTexture:
            guard let s = command.setTexture else { throw SPGBError.truncatedPayload }
            if Int(s.slot) < SPGB_MAX_TEXTURES {
                boundTextures[Int(s.slot)] = resources[s.id]
            }

        case .drawQuad:
            guard let q = command.drawQuad, let target else { throw SPGBError.truncatedPayload }
            guard let texture = boundTextures[0] ?? resources.values.first else {
                throw SPGBError.missingResource(0)
            }
            drawQuad(q, textured: texture, onto: target)
            statistics.quadsDrawn &+= 1

        case .present:
            guard let p = command.present else { throw SPGBError.truncatedPayload }
            guard let texture = resources[p.targetId] else { throw SPGBError.missingResource(p.targetId) }
            present(texture: texture)
            statistics.framesPresented &+= 1
        }
    }

    // MARK: - Metal operations

    private func upload(pixels: Data, to texture: MTLTexture,
                        region header: (id: UInt32, x: UInt32, y: UInt32, w: UInt32, h: UInt32, stride: UInt32)) throws {
        let width = Int(header.w)
        let height = Int(header.h)
        let bytesPerRow = max(Int(header.stride), width) * 4
        guard pixels.count >= bytesPerRow * height else {
            throw SPGBError.truncatedPayload
        }
        var bytes = [UInt8](pixels)
        bytes.withUnsafeMutableBytes { raw in
            texture.replace(region: MTLRegionMake2D(Int(header.x), Int(header.y), width, height),
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: bytesPerRow)
        }
    }

    private func clear(color c: SPGBClear) throws {
        guard let target else { throw SPGBError.truncatedPayload }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw SPGBError.pipelineFailure("clear command buffer")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(c.r), green: Double(c.g),
                                                            blue: Double(c.b), alpha: Double(c.a))
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw SPGBError.pipelineFailure("clear encoder")
        }
        encoder.endEncoding()
        commandBuffer.commit()
    }

    private func drawQuad(_ q: SPGBDrawQuad, textured texture: MTLTexture, onto destination: MTLTexture) {
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer {
            encoder.endEncoding()
            commandBuffer.commit()
        }
        do {
            encoder.setRenderPipelineState(try pipeline(for: destination.pixelFormat))
        } catch {
            return
        }
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentTexture(texture, index: 0)

        // Pixel rect -> clip space for the destination texture.
        let dw = Float(destination.width)
        let dh = Float(destination.height)
        var rect = [q.x / dw * 2.0 - 1.0,      // x0
                    1.0 - q.y / dh * 2.0,      // y0 (top)
                    (q.x + q.w) / dw * 2.0 - 1.0,   // x1
                    1.0 - (q.y + q.h) / dh * 2.0]   // y1 (bottom)
        encoder.setVertexBytes(&rect, length: MemoryLayout<Float>.size * 4, index: 0)

        var uvRect = [q.u0, q.v0, q.u1, q.v1]
        encoder.setFragmentBytes(&uvRect, length: MemoryLayout<Float>.size * 4, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func present(texture: MTLTexture) {
        guard let drawable = currentDrawable,
              let drawableTexture = (drawable as? CAMetalDrawable)?.texture else {
            return // harness not attached to a layer; presentation skipped
        }
        // V-flip: our clip math is top-left origin, presentation is bottom-up.
        drawQuad(SPGBDrawQuad(x: 0, y: 0,
                              w: Float(drawableTexture.width), h: Float(drawableTexture.height),
                              u0: 0, v0: 1, u1: 1, v1: 0, alpha: 1),
                 textured: texture,
                 onto: drawableTexture)
        drawable.present()
    }
}

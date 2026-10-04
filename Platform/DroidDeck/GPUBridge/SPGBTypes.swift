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

/// Swift mirror of Platform/GPUBridge/SPGBProtocol.h — the wire contract
/// between QEMU's virtio-gpu backend and the Metal host renderer.
///
/// The encoder/decoder here deliberately operate on the raw little-endian
/// byte layout (not Swift-native structs) so the on-device G1 harness
/// round-trips the exact stream QEMU will one day produce.

enum SPGBOpcode: UInt32 {
    case nop = 0
    case resourceCreate = 1
    case resourceDestroy = 2
    case transfer2D = 3
    case setTarget = 4
    case clear = 5
    case setTexture = 6
    case drawQuad = 7
    case present = 8
    case submit = 9
}

enum SPGBFormat: UInt32 {
    case invalid = 0
    case rgba8Unorm = 1
    case bgra8Unorm = 2
}

/// Typed representation of one protocol command plus its payload bytes.
struct SPGBCommand {
    var opcode: SPGBOpcode
    var payload: Data

    init(_ opcode: SPGBOpcode, payload: Data = Data()) {
        self.opcode = opcode
        self.payload = payload
    }
}

// MARK: - Payload layout (must match SPGBProtocol.h exactly)

struct SPGBResourceCreate {
    var id: UInt32
    var width: UInt32
    var height: UInt32
    var format: SPGBFormat
}

struct SPGBTransfer2D {
    var id: UInt32
    var x: UInt32, y: UInt32, w: UInt32, h: UInt32
    var stride: UInt32
    var pixels: [UInt8]
}

struct SPGBSetTarget { var id: UInt32 }
struct SPGBClear { var r: Float32, g: Float32, b: Float32, a: Float32 }
struct SPGBSetTexture { var slot: UInt32; var id: UInt32 }
struct SPGBDrawQuad {
    var x: Float32, y: Float32, w: Float32, h: Float32
    var u0: Float32, v0: Float32, u1: Float32, v1: Float32
    var alpha: Float32
}
struct SPGBPresent { var targetId: UInt32 }
struct SPGBSubmit { var flags: UInt32 = 0 }

// MARK: - Stream encoding

enum SPGBStreamEncoder {
    static func encode(_ commands: [SPGBCommand]) -> Data {
        var out = Data()
        for command in commands {
            out.appendLE(command.opcode.rawValue)
            out.appendLE(UInt32(command.payload.count))
            out.append(command.payload)
        }
        return out
    }

    static func resourceCreate(_ r: SPGBResourceCreate) -> SPGBCommand {
        var data = Data()
        data.appendLE(r.id)
        data.appendLE(r.width)
        data.appendLE(r.height)
        data.appendLE(r.format.rawValue)
        return SPGBCommand(.resourceCreate, payload: data)
    }

    static func transfer2D(_ t: SPGBTransfer2D) -> SPGBCommand {
        var data = Data()
        data.appendLE(t.id)
        data.appendLE(t.x); data.appendLE(t.y); data.appendLE(t.w); data.appendLE(t.h)
        data.appendLE(t.stride)
        data.append(contentsOf: t.pixels)
        return SPGBCommand(.transfer2D, payload: data)
    }

    static func setTarget(_ s: SPGBSetTarget) -> SPGBCommand {
        var data = Data()
        data.appendLE(s.id)
        return SPGBCommand(.setTarget, payload: data)
    }

    static func clear(_ c: SPGBClear) -> SPGBCommand {
        var data = Data()
        data.appendLEFloat(c.r); data.appendLEFloat(c.g); data.appendLEFloat(c.b); data.appendLEFloat(c.a)
        return SPGBCommand(.clear, payload: data)
    }

    static func setTexture(_ s: SPGBSetTexture) -> SPGBCommand {
        var data = Data()
        data.appendLE(s.slot)
        data.appendLE(s.id)
        return SPGBCommand(.setTexture, payload: data)
    }

    static func drawQuad(_ q: SPGBDrawQuad) -> SPGBCommand {
        var data = Data()
        data.appendLEFloat(q.x); data.appendLEFloat(q.y); data.appendLEFloat(q.w); data.appendLEFloat(q.h)
        data.appendLEFloat(q.u0); data.appendLEFloat(q.v0); data.appendLEFloat(q.u1); data.appendLEFloat(q.v1)
        data.appendLEFloat(q.alpha)
        return SPGBCommand(.drawQuad, payload: data)
    }

    static func present(_ p: SPGBPresent) -> SPGBCommand {
        var data = Data()
        data.appendLE(p.targetId)
        return SPGBCommand(.present, payload: data)
    }

    static func submit(_ s: SPGBSubmit = SPGBSubmit()) -> SPGBCommand {
        var data = Data()
        data.appendLE(s.flags)
        return SPGBCommand(.submit, payload: data)
    }
}

// MARK: - Stream decoding

enum SPGBStreamDecoder {
    /// Parses a raw stream back into typed commands; throws on malformed input.
    static func decode(_ data: Data) throws -> [SPGBCommand] {
        var commands: [SPGBCommand] = []
        var offset = data.startIndex
        let end = data.endIndex
        while offset < end {
            guard end - offset >= 8 else { throw SPGBError.truncatedHeader }
            guard let opcodeRaw = data.readLE(UInt32.self, at: offset),
                  let size = data.readLE(UInt32.self, at: data.index(offset, offsetBy: 4)) else {
                throw SPGBError.truncatedHeader
            }
            let payloadStart = data.index(offset, offsetBy: 8)
            let payloadEnd = data.index(payloadStart, offsetBy: Int(size))
            guard payloadEnd <= end else { throw SPGBError.truncatedPayload }
            guard let opcode = SPGBOpcode(rawValue: opcodeRaw) else {
                throw SPGBError.unknownOpcode(opcodeRaw)
            }
            commands.append(SPGBCommand(opcode, payload: data.subdata(in: payloadStart..<payloadEnd)))
            offset = payloadEnd
        }
        return commands
    }
}

enum SPGBError: Error, LocalizedError {
    case truncatedHeader
    case truncatedPayload
    case unknownOpcode(UInt32)
    case missingResource(UInt32)
    case metalUnavailable
    case pipelineFailure(String)

    var errorDescription: String? {
        switch self {
        case .truncatedHeader: return "SPGB stream truncated in command header"
        case .truncatedPayload: return "SPGB stream truncated in command payload"
        case .unknownOpcode(let op): return "SPGB unknown opcode \(op)"
        case .missingResource(let id): return "SPGB referenced missing resource \(id)"
        case .metalUnavailable: return "Metal device unavailable"
        case .pipelineFailure(let why): return "Metal pipeline failure: \(why)"
        }
    }
}

// MARK: - Little-endian helpers

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        // Qualified global call: the bare form resolves to Data's instance
        // method on current SDKs, which cannot take `of:`.
        Swift.withUnsafeBytes(of: value.littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendLEFloat(_ value: Float32) {
        appendLE(value.bitPattern)
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at index: Index) -> T? {
        let byteCount = MemoryLayout<T>.size
        guard index + byteCount <= endIndex else { return nil }
        // Data storage is contiguous from startIndex; assemble explicitly
        // (portable across host endianness, no unsafe-buffer ambiguity).
        let chunk = Array(self[index..<(index + byteCount)])
        guard chunk.count == byteCount else { return nil }
        var value = T.zero
        for (offset, byte) in chunk.enumerated() {
            value |= T(truncatingIfNeeded: byte) << (8 * offset)
        }
        return value
    }

    func floatLE(at index: Index) -> Float32? {
        guard let bits = readLE(UInt32.self, at: index) else { return nil }
        return Float32(bitPattern: bits)
    }
}

extension SPGBCommand {
    /// Typed accessors used by the renderer; index math mirrors SPGBProtocol.h.
    var resourceCreate: SPGBResourceCreate? {
        guard opcode == .resourceCreate, payload.count >= 16 else { return nil }
        return SPGBResourceCreate(
            id: payload.readLE(UInt32.self, at: payload.startIndex)!,
            width: payload.readLE(UInt32.self, at: payload.index(payload.startIndex, offsetBy: 4))!,
            height: payload.readLE(UInt32.self, at: payload.index(payload.startIndex, offsetBy: 8))!,
            format: SPGBFormat(rawValue: payload.readLE(UInt32.self, at: payload.index(payload.startIndex, offsetBy: 12))!)!)
    }

    var transfer2DHeader: (id: UInt32, x: UInt32, y: UInt32, w: UInt32, h: UInt32, stride: UInt32)? {
        guard opcode == .transfer2D, payload.count >= 24 else { return nil }
        let s = payload.startIndex
        return (payload.readLE(UInt32.self, at: s)!,
                payload.readLE(UInt32.self, at: payload.index(s, offsetBy: 4))!,
                payload.readLE(UInt32.self, at: payload.index(s, offsetBy: 8))!,
                payload.readLE(UInt32.self, at: payload.index(s, offsetBy: 12))!,
                payload.readLE(UInt32.self, at: payload.index(s, offsetBy: 16))!,
                payload.readLE(UInt32.self, at: payload.index(s, offsetBy: 20))!)
    }

    var pixelPayload: Data? {
        guard opcode == .transfer2D, payload.count > 24 else { return nil }
        return payload.suffix(from: payload.index(payload.startIndex, offsetBy: 24))
    }

    var setTarget: SPGBSetTarget? {
        guard opcode == .setTarget, payload.count >= 4 else { return nil }
        return SPGBSetTarget(id: payload.readLE(UInt32.self, at: payload.startIndex)!)
    }

    var resourceDestroyPayload: UInt32? {
        guard opcode == .resourceDestroy, payload.count >= 4 else { return nil }
        return payload.readLE(UInt32.self, at: payload.startIndex)!
    }

    var clear: SPGBClear? {
        guard opcode == .clear, payload.count >= 16 else { return nil }
        let s = payload.startIndex
        return SPGBClear(r: payload.floatLE(at: s)!,
                         g: payload.floatLE(at: payload.index(s, offsetBy: 4))!,
                         b: payload.floatLE(at: payload.index(s, offsetBy: 8))!,
                         a: payload.floatLE(at: payload.index(s, offsetBy: 12))!)
    }

    var setTexture: SPGBSetTexture? {
        guard opcode == .setTexture, payload.count >= 8 else { return nil }
        let s = payload.startIndex
        return SPGBSetTexture(slot: payload.readLE(UInt32.self, at: s)!,
                              id: payload.readLE(UInt32.self, at: payload.index(s, offsetBy: 4))!)
    }

    var drawQuad: SPGBDrawQuad? {
        guard opcode == .drawQuad, payload.count >= 36 else { return nil }
        let s = payload.startIndex
        func f(_ o: Int) -> Float32 { payload.floatLE(at: payload.index(s, offsetBy: o))! }
        return SPGBDrawQuad(x: f(0), y: f(4), w: f(8), h: f(12),
                            u0: f(16), v0: f(20), u1: f(24), v1: f(28), alpha: f(32))
    }

    var present: SPGBPresent? {
        guard opcode == .present, payload.count >= 4 else { return nil }
        return SPGBPresent(targetId: payload.readLE(UInt32.self, at: payload.startIndex)!)
    }
}

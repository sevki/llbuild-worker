import Foundation

/// A CAS object digest.
public struct CASDigest: Hashable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Lowercase hex, the printed form used for CAS IDs.
    public var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public init?(hex: String) {
        let utf8 = Array(hex.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(utf8.count / 2)
        var index = 0
        while index < utf8.count {
            guard let hi = nibble(utf8[index]), let lo = nibble(utf8[index + 1]) else {
                return nil
            }
            out.append(hi << 4 | lo)
            index += 2
        }
        self.init(bytes: out)
    }
}

/// Identity of a CAS object: what the plugin, the Worker and any verifier
/// must agree on. This is this service's own scheme. It is deliberately not
/// llbuild2's `identify(refs:data:)`; see docs/design.md.
///
/// digest = SHA-256(
///     "llbuild-worker.cas.v1\0"
///     || u64le(refs.count) || refs[0].bytes || refs[1].bytes || ...
///     || u64le(data.count) || data)
public enum CASIdentity {
    public static let schemaName = "llbuild-worker.sha256.v1"
    public static let digestSize = 32

    public static func identify(refs: [CASDigest], data: [UInt8]) -> CASDigest {
        var hasher = SHA256()
        hasher.update(Array("llbuild-worker.cas.v1\u{0}".utf8))
        hasher.update(littleEndian(UInt64(refs.count)))
        for ref in refs {
            hasher.update(ref.bytes)
        }
        hasher.update(littleEndian(UInt64(data.count)))
        hasher.update(data)
        return CASDigest(bytes: hasher.finalize())
    }

    private static func littleEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }
}

/// Minimal SHA-256 (FIPS 180-4), so the identity has no dependency and builds
/// for both the native plugin and the Wasm Worker.
public struct SHA256: Sendable {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var buffer = [UInt8]()
    private var length: UInt64 = 0

    public init() {
        buffer.reserveCapacity(64)
    }

    public static func hash(_ data: [UInt8]) -> [UInt8] {
        var hasher = SHA256()
        hasher.update(data)
        return hasher.finalize()
    }

    public mutating func update(_ data: [UInt8]) {
        length &+= UInt64(data.count)
        var offset = 0
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, data.count)
            buffer.append(contentsOf: data[0..<take])
            offset = take
            if buffer.count == 64 {
                compress(buffer, at: 0)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while data.count - offset >= 64 {
            compress(data, at: offset)
            offset += 64
        }
        if offset < data.count {
            buffer.append(contentsOf: data[offset...])
        }
    }

    public mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var padding: [UInt8] = [0x80]
        let zeros = (55 - Int(length % 64) + 64) % 64
        padding.append(contentsOf: [UInt8](repeating: 0, count: zeros))
        for shift in stride(from: 56, through: 0, by: -8) {
            padding.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        update(padding)
        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in state {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return out
    }

    private mutating func compress(_ block: [UInt8], at start: Int) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = start + i * 4
            w[i] = UInt32(block[j]) << 24 | UInt32(block[j + 1]) << 16
                | UInt32(block[j + 2]) << 8 | UInt32(block[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        state[0] = state[0] &+ a; state[1] = state[1] &+ b
        state[2] = state[2] &+ c; state[3] = state[3] &+ d
        state[4] = state[4] &+ e; state[5] = state[5] &+ f
        state[6] = state[6] &+ g; state[7] = state[7] &+ h
    }

    private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

/// An object's content: what identity is computed over.
public struct CASBlob: Sendable, Equatable {
    public var refs: [CASDigest]
    public var data: [UInt8]

    public init(refs: [CASDigest], data: [UInt8]) {
        self.refs = refs
        self.data = data
    }

    public var digest: CASDigest {
        CASIdentity.identify(refs: refs, data: data)
    }
}

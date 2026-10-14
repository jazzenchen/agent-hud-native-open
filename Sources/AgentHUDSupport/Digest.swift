import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// SHA-256 and SHA-1 digests as byte arrays.
///
/// macOS delegates to CryptoKit; elsewhere the package carries its own implementation of the FIPS 180-4 algorithms,
/// because the source-boundary check keeps the package free of external dependencies and CryptoKit does not exist off
/// Apple platforms.
public enum Digest {
    /// The SHA-256 digest of `data`.
    public static func sha256(_ data: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(SHA256.hash(data: data))
        #else
        return SHA256.digest([UInt8](data))
        #endif
    }

    /// The SHA-1 digest of `data`.
    public static func sha1(_ data: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(Insecure.SHA1.hash(data: data))
        #else
        return SHA1.digest([UInt8](data))
        #endif
    }
}

#if !canImport(CryptoKit)
// Both algorithms written from FIPS 180-4; checked against the specification's message digests in AgentHUDSupportTests.
private enum SHA256 {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var padded = message
        let bits = UInt64(message.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        for block in 0..<(padded.count / 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let base = block &* 64 &+ i &* 4
                w[i] = UInt32(padded[base]) << 24 | UInt32(padded[base + 1]) << 16 | UInt32(padded[base + 2]) << 8 | UInt32(padded[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var v = h
            for i in 0..<64 {
                let s1 = rotr(v[4], 6) ^ rotr(v[4], 11) ^ rotr(v[4], 25)
                let ch = (v[4] & v[5]) ^ (~v[4] & v[6])
                let t1 = v[7] &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(v[0], 2) ^ rotr(v[0], 13) ^ rotr(v[0], 22)
                let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2])
                let t2 = s0 &+ maj
                v[7] = v[6]; v[6] = v[5]; v[5] = v[4]; v[4] = v[3] &+ t1
                v[3] = v[2]; v[2] = v[1]; v[1] = v[0]; v[0] = t1 &+ t2
            }
            for i in 0..<8 { h[i] &+= v[i] }
        }
        return h.flatMap { [$0 >> 24, $0 >> 16, $0 >> 8, $0].map(UInt8.init) }
    }

    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}

private enum SHA1 {
    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]
        var padded = message
        let bits = UInt64(message.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        for block in 0..<(padded.count / 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let base = block &* 64 &+ i &* 4
                w[i] = UInt32(padded[base]) << 24 | UInt32(padded[base + 1]) << 16 | UInt32(padded[base + 2]) << 8 | UInt32(padded[base + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var v = h
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (v[1] & v[2]) | (~v[1] & v[3]); k = 0x5a827999
                case 20..<40: f = v[1] ^ v[2] ^ v[3]; k = 0x6ed9eba1
                case 40..<60: f = (v[1] & v[2]) | (v[1] & v[3]) | (v[2] & v[3]); k = 0x8f1bbcdc
                default: f = v[1] ^ v[2] ^ v[3]; k = 0xca62c1d6
                }
                let temp = rotl(v[0], 5) &+ f &+ v[4] &+ k &+ w[i]
                v[4] = v[3]; v[3] = v[2]; v[2] = rotl(v[1], 30); v[1] = v[0]; v[0] = temp
            }
            for i in 0..<5 { h[i] &+= v[i] }
        }
        return h.flatMap { [$0 >> 24, $0 >> 16, $0 >> 8, $0].map(UInt8.init) }
    }

    private static func rotl(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }
}
#endif

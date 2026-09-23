import Foundation

/// FIPS 180-4 SHA-256. Core may only import Foundation (so it stays testable without the app), which rules
/// out CryptoKit and CommonCrypto. Used to fingerprint typed strings for the audit log and, through HMAC, to
/// sign saved routines.
enum SHA256Digest {
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hexDigest(of inputData: Data) -> String {
        digestBytes(of: inputData).map { String(format: "%02x", $0) }.joined()
    }

    static func digestBytes(of inputData: Data) -> [UInt8] {
        var hashState: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

        // Padding: a 1 bit, zeros up to 56 mod 64 bytes, then the message length in bits as a big-endian UInt64.
        var paddedBytes = [UInt8](inputData)
        let messageLengthInBits = UInt64(paddedBytes.count) * 8
        paddedBytes.append(0x80)
        while paddedBytes.count % 64 != 56 { paddedBytes.append(0) }
        for byteShift in stride(from: 56, through: 0, by: -8) {
            paddedBytes.append(UInt8(truncatingIfNeeded: messageLengthInBits >> UInt64(byteShift)))
        }

        var messageSchedule = [UInt32](repeating: 0, count: 64)
        for blockStartIndex in stride(from: 0, to: paddedBytes.count, by: 64) {
            for wordIndex in 0..<16 {
                let byteIndex = blockStartIndex + wordIndex * 4
                messageSchedule[wordIndex] = UInt32(paddedBytes[byteIndex]) << 24 | UInt32(paddedBytes[byteIndex + 1]) << 16
                    | UInt32(paddedBytes[byteIndex + 2]) << 8 | UInt32(paddedBytes[byteIndex + 3])
            }
            for wordIndex in 16..<64 {
                let earlierWord = messageSchedule[wordIndex - 15]
                let recentWord = messageSchedule[wordIndex - 2]
                let smallSigma0 = rotateRight(earlierWord, by: 7) ^ rotateRight(earlierWord, by: 18) ^ (earlierWord >> 3)
                let smallSigma1 = rotateRight(recentWord, by: 17) ^ rotateRight(recentWord, by: 19) ^ (recentWord >> 10)
                messageSchedule[wordIndex] = messageSchedule[wordIndex - 16] &+ smallSigma0 &+ messageSchedule[wordIndex - 7] &+ smallSigma1
            }

            var workingA = hashState[0], workingB = hashState[1], workingC = hashState[2], workingD = hashState[3]
            var workingE = hashState[4], workingF = hashState[5], workingG = hashState[6], workingH = hashState[7]
            for roundIndex in 0..<64 {
                let bigSigma1 = rotateRight(workingE, by: 6) ^ rotateRight(workingE, by: 11) ^ rotateRight(workingE, by: 25)
                let choose = (workingE & workingF) ^ (~workingE & workingG)
                let firstTemporary = workingH &+ bigSigma1 &+ choose &+ roundConstants[roundIndex] &+ messageSchedule[roundIndex]
                let bigSigma0 = rotateRight(workingA, by: 2) ^ rotateRight(workingA, by: 13) ^ rotateRight(workingA, by: 22)
                let majority = (workingA & workingB) ^ (workingA & workingC) ^ (workingB & workingC)
                let secondTemporary = bigSigma0 &+ majority
                workingH = workingG
                workingG = workingF
                workingF = workingE
                workingE = workingD &+ firstTemporary
                workingD = workingC
                workingC = workingB
                workingB = workingA
                workingA = firstTemporary &+ secondTemporary
            }
            hashState[0] = hashState[0] &+ workingA
            hashState[1] = hashState[1] &+ workingB
            hashState[2] = hashState[2] &+ workingC
            hashState[3] = hashState[3] &+ workingD
            hashState[4] = hashState[4] &+ workingE
            hashState[5] = hashState[5] &+ workingF
            hashState[6] = hashState[6] &+ workingG
            hashState[7] = hashState[7] &+ workingH
        }
        return hashState.flatMap { hashWord in
            stride(from: 24, through: 0, by: -8).map { bitShift in UInt8(truncatingIfNeeded: hashWord >> UInt32(bitShift)) }
        }
    }

    private static func rotateRight(_ value: UInt32, by bitCount: UInt32) -> UInt32 {
        (value >> bitCount) | (value << (32 - bitCount))
    }
}

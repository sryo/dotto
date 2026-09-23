import Foundation

/// Supplies the secret that signs saved routines. The app implements it with a Keychain item, so a routine file
/// written or edited by anything other than this Mac's Dotto fails verification and is never loaded.
protocol RoutineSigningKeyProviding: AnyObject {
    /// Creates the key on first use. Throws when the key can't be read or created.
    func routineSigningKey() throws -> Data
}

enum RoutineIntegritySigning {
    static let minimumSigningKeyByteCount = 32

    /// HMAC-SHA256 over the routine's canonical JSON with its signature field removed, as lowercase hex.
    static func signature(for routine: Routine, signingKey: Data) throws -> String {
        guard signingKey.count >= minimumSigningKeyByteCount else {
            throw RoutineTemplateError(message: "The routine signing key is too short.")
        }
        let authenticationCode = HMACSHA256.authenticationCode(for: try canonicalSignedBytes(of: routine), key: signingKey)
        return authenticationCode.map { String(format: "%02x", $0) }.joined()
    }

    static func hasValidSignature(_ routine: Routine, signingKey: Data) -> Bool {
        guard let recordedSignature = routine.integritySignature,
              let expectedSignature = try? signature(for: routine, signingKey: signingKey) else { return false }
        return constantTimeEquals(Array(recordedSignature.utf8), Array(expectedSignature.utf8))
    }

    /// Canonical bytes, so decoding a saved file and re-encoding it gives back the same bytes.
    private static func canonicalSignedBytes(of routine: Routine) throws -> Data {
        var unsignedRoutine = routine
        unsignedRoutine.integritySignature = nil
        return try CanonicalJSONEncoding.encode(unsignedRoutine)
    }

    private static func constantTimeEquals(_ leftBytes: [UInt8], _ rightBytes: [UInt8]) -> Bool {
        guard leftBytes.count == rightBytes.count else { return false }
        var accumulatedDifference: UInt8 = 0
        for (leftByte, rightByte) in zip(leftBytes, rightBytes) { accumulatedDifference |= leftByte ^ rightByte }
        return accumulatedDifference == 0
    }
}

/// RFC 2104 HMAC over SHA256Digest (CryptoKit is off-limits in Core).
enum HMACSHA256 {
    private static let blockByteCount = 64

    static func authenticationCode(for message: Data, key: Data) -> [UInt8] {
        var blockSizedKey = key.count > blockByteCount ? SHA256Digest.digestBytes(of: key) : [UInt8](key)
        blockSizedKey += [UInt8](repeating: 0, count: blockByteCount - blockSizedKey.count)
        let innerPaddedKey = blockSizedKey.map { $0 ^ 0x36 }
        let outerPaddedKey = blockSizedKey.map { $0 ^ 0x5c }
        let innerDigest = SHA256Digest.digestBytes(of: Data(innerPaddedKey) + message)
        return SHA256Digest.digestBytes(of: Data(outerPaddedKey + innerDigest))
    }
}

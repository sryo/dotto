import Foundation
import Security

/// Keeps the HMAC key that signs saved routine files in the login Keychain, so a routine file written or edited
/// by anything other than Dotto on this Mac fails its signature check. The key is 32 random bytes created on first
/// use and never leaves the Keychain except into this process's memory.
final class KeychainRoutineSigningKeyProvider: RoutineSigningKeyProviding, @unchecked Sendable {
    static let keychainServiceName = "com.sryo.dotto.routine-signing"
    private static let keychainAccountName = "routine-file-hmac-key"
    private static let signingKeyByteCount = 32

    private let stateLock = NSLock()
    private var cachedSigningKey: Data?

    func routineSigningKey() throws -> Data {
        try stateLock.withLock {
            if let cachedSigningKey { return cachedSigningKey }
            let signingKey = try Self.readSigningKeyFromKeychain() ?? Self.createAndStoreSigningKey()
            cachedSigningKey = signingKey
            return signingKey
        }
    }

    private static var baseKeychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainServiceName,
         kSecAttrAccount as String: keychainAccountName]
    }

    private static func readSigningKeyFromKeychain() throws -> Data? {
        var readQuery = baseKeychainQuery
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var copiedItem: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &copiedItem)
        if readStatus == errSecItemNotFound { return nil }
        guard readStatus == errSecSuccess, let storedSigningKey = copiedItem as? Data else {
            throw RoutineTemplateError(message: "The routine signing key couldn't be read from the Keychain (\(describe(readStatus))).")
        }
        return storedSigningKey
    }

    private static func createAndStoreSigningKey() throws -> Data {
        var randomKeyBytes = [UInt8](repeating: 0, count: signingKeyByteCount)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, randomKeyBytes.count, &randomKeyBytes)
        guard randomStatus == errSecSuccess else {
            throw RoutineTemplateError(message: "Dotto couldn't generate a routine signing key (\(describe(randomStatus))).")
        }
        let newSigningKey = Data(randomKeyBytes)
        var addQuery = baseKeychainQuery
        addQuery[kSecValueData as String] = newSigningKey
        addQuery[kSecAttrLabel as String] = "Dotto routine signing key"
        // Readable only on this Mac while the user is logged in; never synced, so another Mac can't sign for this one.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem, let existingSigningKey = try readSigningKeyFromKeychain() {
            return existingSigningKey
        }
        guard addStatus == errSecSuccess else {
            throw RoutineTemplateError(message: "The routine signing key couldn't be saved to the Keychain (\(describe(addStatus))).")
        }
        return newSigningKey
    }

    private static func describe(_ keychainStatus: OSStatus) -> String {
        (SecCopyErrorMessageString(keychainStatus, nil) as String?) ?? "error \(keychainStatus)"
    }
}

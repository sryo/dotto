import Foundation
import Security

/// Why a Keychain operation on the API key failed. It carries only the Keychain's own status text, never the key.
struct AnthropicAPIKeyStoreError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Keeps the user's Anthropic API key in the login Keychain as a generic password, readable only on this Mac while the
/// user is logged in and never synced. The key leaves the Keychain only into this process's memory, and from there
/// only into the `x-api-key` header of a request to api.anthropic.com (`AnthropicMessagesTransport`).
final class AnthropicAPIKeyStore: @unchecked Sendable {
    static let keychainServiceName = "com.sryo.dotto.anthropic-api-key"
    /// The service name the key was saved under before the product was renamed from Again to Dotto.
    static let keychainServiceNameBeforeRename = "com.sryo.again.anthropic-api-key"
    private static let keychainAccountName = "default"

    private let stateLock = NSLock()
    /// Every request reads the key, so it is kept in memory after the first read; saving or deleting replaces it.
    private var cachedAPIKey: String?
    private var cachedAPIKeyIsLoaded = false

    func readAPIKey() throws -> String? {
        try stateLock.withLock {
            if cachedAPIKeyIsLoaded { return cachedAPIKey }
            let storedAPIKey = try Self.readAPIKeyFromKeychain(serviceName: Self.keychainServiceName)
            cachedAPIKey = storedAPIKey
            cachedAPIKeyIsLoaded = true
            return storedAPIKey
        }
    }

    func saveAPIKey(_ apiKey: String) throws {
        try stateLock.withLock {
            try Self.deleteAPIKeyFromKeychain(serviceName: Self.keychainServiceName)
            try Self.addAPIKeyToKeychain(apiKey, serviceName: Self.keychainServiceName)
            cachedAPIKey = apiKey
            cachedAPIKeyIsLoaded = true
        }
    }

    func deleteAPIKey() throws {
        try stateLock.withLock {
            try Self.deleteAPIKeyFromKeychain(serviceName: Self.keychainServiceName)
            cachedAPIKey = nil
            cachedAPIKeyIsLoaded = true
        }
    }

    /// Moves a key saved under `keychainServiceNameBeforeRename` to the current item, then deletes the old item
    /// (`AnthropicAPIKeyRenameMigration` decides). The old item is only checked for existence, not read, unless it is
    /// about to be moved: reading it may make macOS ask the user once, because another app name created it.
    func moveAPIKeySavedBeforeRenameIfNeeded() throws {
        try stateLock.withLock {
            let currentAPIKey = try Self.readAPIKeyFromKeychain(serviceName: Self.keychainServiceName)
            let previousItemExists = try Self.keychainItemExists(serviceName: Self.keychainServiceNameBeforeRename)
            let migrationStep = AnthropicAPIKeyRenameMigration.step(currentItemHoldsAKey: currentAPIKey != nil,
                                                                    previousItemHoldsAKey: previousItemExists)
            switch migrationStep {
            case .leaveKeychainUnchanged:
                return
            case .copyPreviousKeyToCurrentItemThenDeletePreviousItem:
                if let previousAPIKey = try Self.readAPIKeyFromKeychain(serviceName: Self.keychainServiceNameBeforeRename) {
                    try Self.addAPIKeyToKeychain(previousAPIKey, serviceName: Self.keychainServiceName)
                    cachedAPIKey = previousAPIKey
                    cachedAPIKeyIsLoaded = true
                }
                try Self.deleteAPIKeyFromKeychain(serviceName: Self.keychainServiceNameBeforeRename)
            }
        }
    }

    private static func baseKeychainQuery(serviceName: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: serviceName,
         kSecAttrAccount as String: keychainAccountName]
    }

    private static func addAPIKeyToKeychain(_ apiKey: String, serviceName: String) throws {
        var addQuery = baseKeychainQuery(serviceName: serviceName)
        addQuery[kSecValueData as String] = Data(apiKey.utf8)
        addQuery[kSecAttrLabel as String] = "Dotto Anthropic API key"
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AnthropicAPIKeyStoreError(message: "The API key couldn't be saved to the Keychain (\(describe(addStatus))).")
        }
    }

    /// Asks for no data, so it never triggers a Keychain access prompt.
    private static func keychainItemExists(serviceName: String) throws -> Bool {
        var existenceQuery = baseKeychainQuery(serviceName: serviceName)
        existenceQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        let existenceStatus = SecItemCopyMatching(existenceQuery as CFDictionary, nil)
        if existenceStatus == errSecItemNotFound { return false }
        guard existenceStatus == errSecSuccess else {
            throw AnthropicAPIKeyStoreError(message: "The Keychain couldn't be searched for an API key (\(describe(existenceStatus))).")
        }
        return true
    }

    private static func readAPIKeyFromKeychain(serviceName: String) throws -> String? {
        var readQuery = baseKeychainQuery(serviceName: serviceName)
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var copiedItem: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &copiedItem)
        if readStatus == errSecItemNotFound { return nil }
        guard readStatus == errSecSuccess, let storedKeyData = copiedItem as? Data else {
            throw AnthropicAPIKeyStoreError(message: "The API key couldn't be read from the Keychain (\(describe(readStatus))).")
        }
        let storedAPIKey = String(decoding: storedKeyData, as: UTF8.self)
        return storedAPIKey.isEmpty ? nil : storedAPIKey
    }

    private static func deleteAPIKeyFromKeychain(serviceName: String) throws {
        let deleteStatus = SecItemDelete(baseKeychainQuery(serviceName: serviceName) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw AnthropicAPIKeyStoreError(message: "The API key couldn't be removed from the Keychain (\(describe(deleteStatus))).")
        }
    }

    private static func describe(_ keychainStatus: OSStatus) -> String {
        (SecCopyErrorMessageString(keychainStatus, nil) as String?) ?? "error \(keychainStatus)"
    }
}

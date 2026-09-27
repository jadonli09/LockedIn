//
//  UnlockCredentialStore.swift
//  LockedIn
//
//  The Mac password for face unlock lives in the app's own Keychain item. It is
//  read only after a face match on the real lock screen, handed to the helper
//  over the app-private XPC connection for typing, and zeroed straight after.
//
//  It used to live in the helper, but an XPC service's Keychain writes fail
//  with errSecInteractionNotAllowed, while the app's (like the face-data key)
//  work — so the app owns it.
//
//  Adapted from Glance (github.com/jonnyoo/glance, MIT) KeychainManager /
//  SecureCredentialManager, simplified: the Keychain item itself is the
//  at-rest protection (ACL'd to the app's code signature, device-only).
//

import Foundation
import Security

enum UnlockCredentialError: LocalizedError {
    case emptyPassword
    case notStored
    case unexpectedData
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyPassword: return "Password cannot be empty."
        case .notStored: return "No Mac password is stored yet."
        case .unexpectedData: return "The stored password had an unexpected format."
        case .osStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

enum UnlockCredentialStore {
    private static let service = "com.jadonli.lockedin"
    private static let account = "faceUnlockPassword"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Attributes-only existence check — never returns the secret.
    static func exists() -> Bool {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess
    }

    /// Replaces any existing item.
    static func save(_ password: String) throws {
        guard let bytes = password.data(using: .utf8), !bytes.isEmpty else {
            throw UnlockCredentialError.emptyPassword
        }
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = bytes
        addQuery[kSecAttrLabel as String] = "LockedIn Face Unlock"
        // Readable whenever the login keychain is unlocked — which it still is
        // while the screen is locked, the one moment this has to work.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw UnlockCredentialError.osStatus(status) }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw UnlockCredentialError.osStatus(status)
        }
    }

    /// Caller MUST zero the returned bytes (`resetBytes(in:)`) after use.
    static func read() throws -> Data {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw UnlockCredentialError.unexpectedData }
            return data
        case errSecItemNotFound:
            throw UnlockCredentialError.notStored
        default:
            throw UnlockCredentialError.osStatus(status)
        }
    }
}

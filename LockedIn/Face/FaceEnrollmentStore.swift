//
//  FaceEnrollmentStore.swift
//  LockedIn
//
//  Enrolled identities, persisted AES-GCM-encrypted in the app's sandbox
//  container under a random key held in the app's Keychain. Embeddings can't
//  be turned back into a face, but they are still biometric-derived data and
//  never sit on disk in the clear. Decision vs. Glance: no Touch ID session —
//  LockedIn's store must be readable silently while a focus session runs.
//
//  Refuses to write when the last load failed, so an unreadable store can never
//  be silently replaced by an empty one.
//

import Combine
import CryptoKit
import Foundation
import Security

enum SecureFaceStoreError: LocalizedError {
    case keyUnavailable(OSStatus)
    case decryptionFailed
    case storeUnreadable

    var errorDescription: String? {
        switch self {
        case .keyUnavailable(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Couldn't read the face-data key from the Keychain: \(message)"
        case .decryptionFailed:
            return "Enrolled face data couldn't be decrypted. Delete the enrollment and enroll again."
        case .storeUnreadable:
            return "Your enrolled face couldn't be read, so nothing was saved — writing now would overwrite it."
        }
    }
}

enum SecureFaceStore {
    private static let keychainService = "com.jadonli.lockedin"
    private static let keychainAccount = "faceStoreKey"

    private static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("LockedIn", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("face-identities.enc")
    }()

    static var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func load() throws -> [FaceIdentity] {
        guard let ciphertext = try? Data(contentsOf: fileURL) else { return [] }
        let key = try loadKey(createIfMissing: false)
        guard let key else { throw SecureFaceStoreError.decryptionFailed }
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            let plaintext = try AES.GCM.open(sealed, using: key)
            return try JSONDecoder().decode([FaceIdentity].self, from: plaintext)
        } catch {
            throw SecureFaceStoreError.decryptionFailed
        }
    }

    static func save(_ identities: [FaceIdentity]) throws {
        guard let key = try loadKey(createIfMissing: true) else {
            throw SecureFaceStoreError.keyUnavailable(errSecItemNotFound)
        }
        let plaintext = try JSONEncoder().encode(identities)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw SecureFaceStoreError.decryptionFailed }
        try combined.write(to: fileURL, options: .atomic)
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: fileURL)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Returns nil (not an error) when there's no key yet and creation wasn't requested.
    private static func loadKey(createIfMissing: Bool) throws -> SymmetricKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw SecureFaceStoreError.keyUnavailable(status) }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            guard createIfMissing else { return nil }
            let key = SymmetricKey(size: .bits256)
            query.removeValue(forKey: kSecReturnData as String)
            query.removeValue(forKey: kSecMatchLimit as String)
            query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
            query[kSecAttrLabel as String] = "LockedIn face data key"
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecureFaceStoreError.keyUnavailable(addStatus) }
            return key
        default:
            throw SecureFaceStoreError.keyUnavailable(status)
        }
    }
}

@MainActor
final class FaceEnrollmentStore: ObservableObject {
    static let shared = FaceEnrollmentStore()

    @Published private(set) var identities: [FaceIdentity] = []
    /// Non-nil when the encrypted store exists but couldn't be read; writes are blocked.
    @Published private(set) var loadFailure: String?
    private var hasLoadedSuccessfully = false

    /// LockedIn enrolls one person — the Mac's user. Kept as an array on disk
    /// so multiple appearances (glasses / no glasses) can be added later.
    var primary: FaceIdentity? { identities.first }
    var hasEnrollment: Bool { !identities.isEmpty }

    private init() {
        reload()
    }

    func reload() {
        do {
            identities = try SecureFaceStore.load()
            hasLoadedSuccessfully = true
            loadFailure = nil
        } catch {
            identities = []
            loadFailure = error.localizedDescription
        }
    }

    /// Commits a whole guided enrollment in a single write, replacing any previous one.
    func commitEnrollment(name: String, samples: [FaceSample], embedder: FaceEmbedder) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !samples.isEmpty else { return }
        guard hasLoadedSuccessfully else { throw SecureFaceStoreError.storeUnreadable }
        let identity = FaceIdentity(
            id: UUID(),
            name: trimmed.isEmpty ? NSFullUserName() : trimmed,
            samples: samples,
            modelIdentifier: embedder.modelIdentifier,
            embeddingDimension: embedder.embeddingDimension,
            createdAt: Date()
        )
        try SecureFaceStore.save([identity])
        identities = [identity]
    }

    func deleteAll() {
        identities = []
        SecureFaceStore.deleteAll()
        loadFailure = nil
        hasLoadedSuccessfully = true
    }

    /// True if the enrollment was captured with a different embedder than the one running now.
    var isStale: Bool {
        guard let primary else { return false }
        return primary.isStale(comparedTo: FaceRecognitionPipeline.shared.embedder.modelIdentifier)
    }
}

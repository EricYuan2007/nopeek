import Foundation
import Security
import Vision

/// Enrolled owner feature prints, persisted in the Keychain (generic-password item,
/// ThisDeviceOnly / WhenUnlocked). Prints are archived Vision observations — opaque
/// geometry descriptors, NOT images; the original pixels are never stored anywhere.
enum OwnerStore {

    private static let service = "com.nopeek.NoPeek"
    private static let account = "owner-featureprints-v1"

    enum StoreError: Error {
        case keychain(OSStatus)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ prints: [VNFeaturePrintObservation]) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: prints, requiringSecureCoding: true)
        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        Log.detection.info("keychain save: delete=\(deleteStatus) add=\(status) bytes=\(data.count)")
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    static func load() -> [VNFeaturePrintObservation] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            Log.detection.warning("keychain load: status=\(status) (item missing or unreadable)")
            return []
        }
        let classes: [AnyClass] = [NSArray.self, VNFeaturePrintObservation.self,
                                   NSData.self, NSNumber.self, NSValue.self]
        do {
            let prints = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data)
                as? [VNFeaturePrintObservation] ?? []
            Log.detection.info("keychain load: \(prints.count) prints from \(data.count) bytes")
            return prints
        } catch {
            // e.g. feature-print revision changed after an OS upgrade → re-enroll.
            Log.app.error("owner prints failed to unarchive (\(error.localizedDescription)) — please re-enroll")
            return []
        }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

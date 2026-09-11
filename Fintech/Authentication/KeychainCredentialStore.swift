import Foundation
import Security

actor KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let account = "session"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: String = "com.ferrari.Fintech.authentication") {
        self.service = service
    }

    func load() async throws -> AuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.invalidData
            }

            do {
                let tokens = try decoder.decode(AuthTokens.self, from: data)
                guard tokens.isValid else { throw KeychainError.invalidData }
                return tokens
            } catch let error as KeychainError {
                throw error
            } catch {
                throw KeychainError.invalidData
            }
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw KeychainError.interactionNotAllowed
        default:
            throw KeychainError.unexpectedStatus(Int32(status))
        }
    }

    func save(_ tokens: AuthTokens) async throws {
        guard tokens.isValid else { throw KeychainError.invalidData }
        let data: Data

        do {
            data = try encoder.encode(tokens)
        } catch {
            throw KeychainError.invalidData
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var addQuery = baseQuery
        addQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw keychainError(for: updateStatus)
            }
        case errSecInteractionNotAllowed:
            throw KeychainError.interactionNotAllowed
        default:
            throw keychainError(for: addStatus)
        }
    }

    func delete() async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(for: status)
        }
    }

    private func keychainError(for status: OSStatus) -> KeychainError {
        switch status {
        case errSecItemNotFound:
            .itemNotFound
        case errSecInteractionNotAllowed:
            .interactionNotAllowed
        default:
            .unexpectedStatus(Int32(status))
        }
    }
}

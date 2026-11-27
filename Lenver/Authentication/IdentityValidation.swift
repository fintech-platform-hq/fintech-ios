import Foundation

nonisolated enum IdentityValidation {
    static func normalizedEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidEmail(_ value: String) -> Bool {
        let email = normalizedEmail(value)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let local = parts.first, !local.isEmpty,
              let domain = parts.last, domain.contains("."),
              !local.hasPrefix("."), !local.hasSuffix("."), !local.contains(".."),
              !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains(".."),
              email.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        return true
    }

    static func isNewPassword(_ value: String) -> Bool { (12...128).contains(value.count) }

    static func isExistingPassword(_ value: String) -> Bool { (1...128).contains(value.count) }

    static func isVerificationCode(_ value: String) -> Bool {
        value.count == 6 && value.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

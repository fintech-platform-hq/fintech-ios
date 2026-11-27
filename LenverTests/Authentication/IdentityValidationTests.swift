import Testing
@testable import Lenver

struct IdentityValidationTests {
    @Test(arguments: [" person@example.com ", "maria@exemplo.com.br"])
    func acceptsEmailAndTrimsWhitespace(_ email: String) {
        #expect(IdentityValidation.isValidEmail(email))
        #expect(IdentityValidation.normalizedEmail(email).contains(" ") == false)
    }

    @Test(arguments: ["", "person", "@example.com", "person@", "person@example", "person @example.com", "person..name@example.com"])
    func rejectsMalformedEmail(_ email: String) {
        #expect(!IdentityValidation.isValidEmail(email))
    }

    @Test
    func appliesPasswordLengthOnlyToNewPasswords() {
        #expect(!IdentityValidation.isNewPassword(String(repeating: "a", count: 11)))
        #expect(IdentityValidation.isNewPassword(String(repeating: "a", count: 12)))
        #expect(IdentityValidation.isNewPassword(String(repeating: "a", count: 128)))
        #expect(!IdentityValidation.isNewPassword(String(repeating: "a", count: 129)))
        #expect(IdentityValidation.isExistingPassword("legacy"))
        #expect(!IdentityValidation.isExistingPassword(""))
    }

    @Test
    func validatesSixAsciiDigits() {
        #expect(IdentityValidation.isVerificationCode("012345"))
        #expect(!IdentityValidation.isVerificationCode("12345"))
        #expect(!IdentityValidation.isVerificationCode("１２３４５６"))
    }
}

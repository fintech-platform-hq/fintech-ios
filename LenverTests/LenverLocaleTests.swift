import Foundation
import Testing
@testable import Lenver

struct LenverLocaleTests {
    @Test
    func languageSelectsFormattingLocaleWithoutUsingDeviceRegion() {
        #expect(LenverLocale.forLanguage("pt-BR") == Locale(identifier: "pt_BR"))
        #expect(LenverLocale.forLanguage("en") == Locale(identifier: "en_US"))
        #expect(LenverLocale.forLanguage("en-GB") == Locale(identifier: "en_US"))
    }

    @MainActor
    @Test
    func currencyKeepsBRLAndUsesSelectedLanguageSeparators() {
        let brazilian = MvpAccountViewModel.money("123450", locale: LenverLocale.forLanguage("pt-BR"))
        let english = MvpAccountViewModel.money("123450", locale: LenverLocale.forLanguage("en"))
        #expect(brazilian.filter { !$0.isWhitespace } == "R$1.234,50")
        #expect(english.filter { !$0.isWhitespace } == "R$1,234.50")
    }

    @Test
    func transactionEntryKeepsBRLAndUsesSelectedLanguageSeparators() {
        let brazilian = CreateTransactionInputNormalizer.formattedSignedBRLAmount(
            from: "123450", transactionType: .expense,
            locale: LenverLocale.forLanguage("pt-BR")
        )
        let english = CreateTransactionInputNormalizer.formattedSignedBRLAmount(
            from: "123450", transactionType: .expense,
            locale: LenverLocale.forLanguage("en")
        )

        #expect(brazilian == "-R$ 1.234,50")
        #expect(english == "-R$1,234.50")
    }
}

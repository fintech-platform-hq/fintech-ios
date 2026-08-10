import Foundation

nonisolated enum CreateTransactionInputNormalizer {
    static let amountDigitLimit = 9

    static func limitedAmountDigits(
        from proposedValue: String,
        preserving previousValue: String
    ) -> String {
        guard !proposedValue.isEmpty else {
            return ""
        }

        let extractedDigits = amountDigits(from: proposedValue)

        guard !extractedDigits.isEmpty else {
            return previousValue
        }

        return String(extractedDigits.prefix(amountDigitLimit))
    }

    static func amountDigits(from input: String) -> String {
        String(
            input.filter { character in
                guard let byte = character.asciiValue else {
                    return false
                }

                return (48...57).contains(byte)
            }
        )
    }

    static func replacingAmountDigits(
        _ currentDigits: String,
        in range: Range<Int>,
        with replacement: String
    ) -> String {
        let digits = Array(currentDigits.prefix(amountDigitLimit))
        let lowerBound = min(max(0, range.lowerBound), digits.count)
        let upperBound = min(
            max(lowerBound, range.upperBound),
            digits.count
        )
        let replacementDigits = amountDigits(from: replacement)

        guard replacement.isEmpty || !replacementDigits.isEmpty else {
            return String(digits)
        }

        let retainedDigitCount = digits.count - (upperBound - lowerBound)
        let availableDigitCount = max(
            0,
            amountDigitLimit - retainedDigitCount
        )
        let acceptedReplacement = replacementDigits.prefix(
            availableDigitCount
        )
        var updatedDigits = digits
        updatedDigits.replaceSubrange(
            lowerBound..<upperBound,
            with: acceptedReplacement
        )

        return String(updatedDigits)
    }

    static func rawDigitRange(
        in formattedAmount: String,
        selectedUTF16Range selection: NSRange,
        rawDigitCount: Int
    ) -> Range<Int>? {
        guard selection.length > 0, rawDigitCount > 0 else {
            return nil
        }

        let formattedLength = formattedAmount.utf16.count
        let selectionStart = min(max(0, selection.location), formattedLength)
        let selectionEnd = min(
            max(selectionStart, NSMaxRange(selection)),
            formattedLength
        )

        if selectionStart == 0, selectionEnd == formattedLength {
            return 0..<rawDigitCount
        }

        let displayedDigitLocations = formattedAmount.utf16
            .enumerated()
            .compactMap { offset, codeUnit in
                (48...57).contains(codeUnit) ? offset : nil
            }
        let rawDigitOffset = rawDigitCount - displayedDigitLocations.count
        let selectedRawIndices = displayedDigitLocations
            .enumerated()
            .compactMap { displayedIndex, location -> Int? in
                guard selectionStart <= location, location < selectionEnd else {
                    return nil
                }

                let rawIndex = rawDigitOffset + displayedIndex
                return (0..<rawDigitCount).contains(rawIndex)
                    ? rawIndex
                    : nil
            }

        guard let firstIndex = selectedRawIndices.first,
              let lastIndex = selectedRawIndices.last else {
            return nil
        }

        return firstIndex..<(lastIndex + 1)
    }

    static func formattedBRLAmount(from digits: String) -> String {
        guard !digits.isEmpty, let amountMinor = Int(digits) else {
            return ""
        }

        let reais = amountMinor / 100
        let cents = amountMinor % 100
        let centsText = String(format: "%02d", cents)

        return "R$ \(groupedReais(reais)),\(centsText)"
    }

    static func formattedSignedBRLAmount(
        from digits: String,
        transactionType: TransactionType
    ) -> String {
        let unsignedAmount = formattedBRLAmount(from: digits)

        guard !unsignedAmount.isEmpty else {
            return "\(transactionType.amountPresentationSign)R$ 0,00"
        }

        return "\(transactionType.amountPresentationSign)\(unsignedAmount)"
    }

    private static func groupedReais(_ value: Int) -> String {
        let digits = Array(String(value))
        var grouped = ""

        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index).isMultiple(of: 3) {
                grouped.append(".")
            }

            grouped.append(digit)
        }

        return grouped
    }
}

import SwiftUI
import UIKit

struct CurrencyAmountTextField: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var digits: String
    let replaceDigits: (Range<Int>, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.delegate = context.coordinator
        textField.keyboardType = .numberPad
        textField.textAlignment = .right
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.textColor = .label
        textField.placeholder = "R$ 0,00"
        textField.accessibilityLabel = "Amount in BRL"
        textField.accessibilityIdentifier = "createTransaction.amount"
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        textField.isEnabled = isEnabled

        let formattedAmount = CreateTransactionInputNormalizer
            .formattedBRLAmount(from: digits)

        if textField.text != formattedAmount {
            textField.text = formattedAmount
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CurrencyAmountTextField

        init(parent: CurrencyAmountTextField) {
            self.parent = parent
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            moveCaretToEnd(of: textField)
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let replacementRange: Range<Int>

            if range.length > 0 {
                guard let selectedDigitRange = CreateTransactionInputNormalizer
                    .rawDigitRange(
                        in: textField.text ?? "",
                        selectedUTF16Range: range,
                        rawDigitCount: parent.digits.count
                    ) else {
                    return false
                }

                replacementRange = selectedDigitRange
            } else if string.isEmpty {
                let lastDigitIndex = max(0, parent.digits.count - 1)
                replacementRange = lastDigitIndex..<parent.digits.count
            } else {
                replacementRange = parent.digits.count..<parent.digits.count
            }

            parent.replaceDigits(replacementRange, string)
            textField.text = CreateTransactionInputNormalizer
                .formattedBRLAmount(from: parent.digits)
            moveCaretToEndAfterFormatting(textField)
            return false
        }

        private func moveCaretToEndAfterFormatting(_ textField: UITextField) {
            // UIKit can replace selection after shouldChangeCharactersIn returns.
            Task { @MainActor [weak textField] in
                await Task.yield()

                guard let textField, textField.isFirstResponder else {
                    return
                }

                moveCaretToEnd(of: textField)
            }
        }

        private func moveCaretToEnd(of textField: UITextField) {
            let end = textField.endOfDocument

            textField.selectedTextRange = textField.textRange(
                from: end,
                to: end
            )
        }
    }
}

struct LimitedTextEditor: UIViewRepresentable {
    static let minimumVisibleLineCount = 4
    static let maximumVisibleLineCount = 4
    static let visibleLineCount = 4
    static let baseLineHeight: CGFloat = 20
    static let verticalContentInset: CGFloat = 4

    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var scaledLineHeight = baseLineHeight
    @Binding var text: String
    let characterLimit: Int

    static func boundedHeight(for lineHeight: CGFloat) -> CGFloat {
        (lineHeight * CGFloat(visibleLineCount)) + verticalContentInset
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> BoundedTextEditorContainer {
        let container = BoundedTextEditorContainer()
        let textView = container.textView
        container.boundedHeight = Self.boundedHeight(
            for: scaledLineHeight
        )
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(
            top: 2,
            left: 0,
            bottom: 2,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = true
        textView.autocapitalizationType = .sentences
        textView.accessibilityLabel = "Transaction description, optional"
        textView.accessibilityIdentifier = "createTransaction.description"
        return container
    }

    func updateUIView(
        _ container: BoundedTextEditorContainer,
        context: Context
    ) {
        context.coordinator.parent = self
        container.boundedHeight = Self.boundedHeight(
            for: scaledLineHeight
        )

        let textView = container.textView
        textView.isEditable = isEnabled

        if textView.markedTextRange == nil, textView.text != text {
            textView.text = text
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView container: BoundedTextEditorContainer,
        context: Context
    ) -> CGSize? {
        return CGSize(
            width: proposal.width ?? max(container.bounds.width, 1),
            height: Self.boundedHeight(for: scaledLineHeight)
        )
    }

    final class BoundedTextEditorContainer: UIView {
        let textView = NonExpandingTextView()

        var boundedHeight: CGFloat = 0 {
            didSet {
                guard boundedHeight != oldValue else {
                    return
                }

                invalidateIntrinsicContentSize()
            }
        }

        override var intrinsicContentSize: CGSize {
            CGSize(
                width: UIView.noIntrinsicMetric,
                height: boundedHeight
            )
        }

        override init(frame: CGRect) {
            super.init(frame: frame)

            clipsToBounds = true
            textView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(textView)

            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: trailingAnchor),
                textView.topAnchor.constraint(equalTo: topAnchor),
                textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func sizeThatFits(_ size: CGSize) -> CGSize {
            CGSize(width: size.width, height: boundedHeight)
        }
    }

    final class NonExpandingTextView: UITextView {
        override var intrinsicContentSize: CGSize {
            CGSize(
                width: UIView.noIntrinsicMetric,
                height: UIView.noIntrinsicMetric
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LimitedTextEditor

        init(parent: LimitedTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            let currentText = textView.text ?? ""

            guard let swiftRange = Range(range, in: currentText) else {
                return false
            }

            let proposedText = currentText.replacingCharacters(
                in: swiftRange,
                with: replacement
            )

            guard proposedText.count > parent.characterLimit else {
                return true
            }

            let retainedText = currentText.replacingCharacters(
                in: swiftRange,
                with: ""
            )
            let availableCharacterCount = max(
                0,
                parent.characterLimit - retainedText.count
            )
            let acceptedReplacement = String(
                replacement.prefix(availableCharacterCount)
            )
            let limitedText = currentText.replacingCharacters(
                in: swiftRange,
                with: acceptedReplacement
            )

            parent.text = limitedText
            textView.text = limitedText
            textView.selectedRange = NSRange(
                location: range.location + acceptedReplacement.utf16.count,
                length: 0
            )
            return false
        }
    }
}

struct KeyboardDismissalTapObserver: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: AttachmentView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(to: view.window)
    }

    static func dismantleUIView(
        _ view: AttachmentView,
        coordinator: Coordinator
    ) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: KeyboardDismissalTapObserver
        weak var attachedWindow: UIWindow?
        private var tapRecognizer: UITapGestureRecognizer!

        init(parent: KeyboardDismissalTapObserver) {
            self.parent = parent
            super.init()

            tapRecognizer = UITapGestureRecognizer(
                target: self,
                action: #selector(handleTap)
            )
            tapRecognizer.cancelsTouchesInView = false
            tapRecognizer.delegate = self
        }

        func attach(to window: UIWindow?) {
            guard attachedWindow !== window else {
                return
            }

            detach()
            attachedWindow = window
            window?.addGestureRecognizer(tapRecognizer)
        }

        func detach() {
            attachedWindow?.removeGestureRecognizer(tapRecognizer)
            attachedWindow = nil
        }

        @objc
        private func handleTap() {
            parent.action()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            var touchedView = touch.view

            while let currentView = touchedView {
                if currentView is UITextField || currentView is UITextView {
                    return false
                }

                touchedView = currentView.superview
            }

            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    @MainActor
    final class AttachmentView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }
    }
}

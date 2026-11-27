import AuthenticationServices
import SwiftUI

struct IdentityVerificationView: View {
    let service: IdentityService
    let session: AuthenticationSession
    let model: AuthenticationViewModel

    @State private var code = ""
    @State private var work = IdentityFormWork()

    var body: some View {
        NavigationStack {
            Form {
                if let identity = model.identityStatus {
                    Section {
                        if let email = identity.email { Text(email) }
                        Text("Verify your email before accessing financial information.")
                        IdentityCodeField(code: $code)
                        Button("Confirm code") {
                            work.run(.verifyEmail) {
                                let generation = await session.currentGeneration()
                                try await service.verify(code: code, generation: generation)
                                code = ""
                                await model.reloadIdentity()
                            }
                        }
                        .disabled(!code.isIdentityCode)
                        Button("Check account status") { work.run(.checkStatus) { await model.reloadIdentity() } }
                        NavigationLink("Change verification email") {
                            IdentityPendingEmailView(service: service, session: session, model: model)
                        }
                        Button("Send verification code") {
                            work.run(.sendVerification, success: "Check your email for a verification code.") {
                                try await service.sendVerification(generation: session.currentGeneration())
                            }
                        }
                    }
                    .disabled(work.busy)
                } else {
                    Section {
                        Text("Your account status could not be confirmed.")
                        Button("Check account status") { work.run(.checkStatus) { await model.reloadIdentity() } }
                            .disabled(work.busy)
                    }
                }
                IdentityFeedback(work: work)
                Section {
                    Button("Sign Out", role: .destructive) { Task { await model.logout() } }
                }
            }
            .navigationTitle("Verify your email")
            .onDisappear { work.cancel() }
        }
    }
}

struct IdentityRecoveryView: View {
    let service: IdentityService

    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var requested = false
    @State private var finished = false
    @State private var work = IdentityFormWork()

    var body: some View {
        Form {
            if finished {
                Text("Your password was updated. Sign in with your new password.")
            } else {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: email) { _, _ in
                            requested = false
                            code = ""
                        }
                    Button(LocalizedStringKey(requested ? "Send another code" : "Send recovery code")) {
                        work.run(.recoveryRequest) {
                            try await service.requestRecovery(email: IdentityValidation.normalizedEmail(email))
                            requested = true
                        }
                    }
                    .disabled(!IdentityValidation.isValidEmail(email))
                }
                if requested {
                    Section {
                        Text("If your account is eligible, you’ll receive a code at its verified email.")
                        IdentityCodeField(code: $code)
                        SecureField("New password", text: $password).textContentType(.newPassword)
                        SecureField("Confirm new password", text: $confirmation).textContentType(.newPassword)
                        Button("Save password") {
                            work.run(.recoverPassword) {
                                try await service.recover(email: IdentityValidation.normalizedEmail(email), code: code, password: password)
                                password = ""
                                confirmation = ""
                                code = ""
                                finished = true
                            }
                        }
                        .disabled(!code.isIdentityCode || !password.isIdentityPassword || password != confirmation)
                    }
                }
            }
            IdentityFeedback(work: work)
        }
        .disabled(work.busy)
        .navigationTitle("Recover password")
        .onDisappear { work.cancel() }
    }
}

struct UserIdentityView: View {
    let service: IdentityService
    let session: AuthenticationSession
    let model: AuthenticationViewModel

    @State private var showsLink = false
    @State private var confirmsSignOut = false
    @State private var work = IdentityFormWork()
    @State private var receiptWork = IdentityFormWork()

    var body: some View {
        List {
            if let status = model.identityStatus, let generation = model.identityGeneration {
                Section("Identity") {
                    if let email = status.email { LabeledContent("Email", value: email) }
                    LabeledContent {
                        Text(LocalizedStringKey(status.authMethod == "apple" ? "Apple" : "Password"))
                    } label: {
                        Text("Signed in with")
                    }
                }
                Section("Sign-in methods") {
                    LabeledContent {
                        Text(LocalizedStringKey(
                                status.passwordVerified ? "Verified" : status.hasPassword ? "Verification pending" : "Not linked"
                        ))
                    } label: {
                        Text("Password")
                    }
                    LabeledContent {
                        Text(LocalizedStringKey(status.hasApple ? "Linked" : "Not linked"))
                    } label: {
                        Text("Apple")
                    }
                    if model.pendingMethodIntent != nil, !model.methodChangeInProgress {
                        Text("The sign-in method change could not be confirmed. Keep using your current method and do not repeat it yet.")
                        Button("Check sign-in method change") {
                            receiptWork.run(.checkStatus) {
                                if try await model.checkIdentityMethod() {
                                    receiptWork.feedback = "Sign-in method change confirmed."
                                } else {
                                    receiptWork.feedback = "The result is still unknown."
                                }
                            }
                        }
                        .disabled(receiptWork.busy || model.methodChangeInProgress)
                    } else if !model.methodRecoveryReady {
                        Text("Sign-in method changes are temporarily unavailable.")
                        Button("Check account status") { Task { await model.reloadIdentity() } }
                    }
                    IdentityFeedback(work: receiptWork)
                    if status.passwordVerified, status.authMethod == "password", !status.hasApple {
                        if !model.appleAuthorizationAvailable {
                            Text("Apple sign-in is unavailable in this build.")
                        } else {
                            Button("Link Apple Account") {
                                work.run(.linkApple) {
                                    try await model.requestAppleLink(fromSecurity: true)
                                    showsLink = true
                                }
                            }
                            .disabled(!model.canChangeMethods)
                        }
                    }
                    if status.authMethod == "apple", status.hasApple {
                        NavigationLink(LocalizedStringKey(status.hasPassword ? "Unlink email and password" : "Link email and password")) {
                            PasswordMethodView(service: service, generation: generation, model: model, removing: status.hasPassword)
                        }
                        .disabled(!model.canChangeMethods)
                    }
                    if status.hasApple, status.passwordVerified {
                        if status.authMethod == "password" {
                            NavigationLink("Unlink Apple Account") {
                                UnlinkAppleView(service: service, generation: generation, model: model)
                            }
                            .disabled(!model.canChangeMethods)
                        } else {
                            Text("Sign in with your password to unlink Apple.")
                        }
                    }
                }
                Section("Security") {
                    if status.passwordVerified {
                        NavigationLink("Change password") {
                            IdentityPasswordChangeView(service: service, session: session)
                        }
                    }
                    Button("Sign Out", role: .destructive) { confirmsSignOut = true }
                }
            }
            Section {
                NavigationLink("Privacy") {
                    List {
                        Text("Your methods and current session control access to your Lenver account.")
                        LabeledContent {
                            Text("Unavailable in this version")
                        } label: {
                            Text("Delete account")
                        }
                    }
                    .navigationTitle("Privacy")
                }
                NavigationLink("Preferences") {
                    Form {
                        Text("Choose Lenver’s language in system settings. If this link opens Settings, select Lenver under Apps.")
                        Link("Open system settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    }
                    .navigationTitle("Preferences")
                }
                NavigationLink("Support") {
                    List {
                        Link("Recover your Apple Account", destination: URL(string: "https://iforgot.apple.com")!)
                        Text("To recover your Lenver password, use password recovery on the sign-in screen.")
                    }
                    .navigationTitle("Support")
                }
            }
            IdentityFeedback(work: work)
        }
        .onChange(of: model.pendingMethodIntent) { _, intent in
            if intent != nil { receiptWork.feedback = nil }
        }
        .navigationTitle("User Account")
        .confirmationDialog("Sign out?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await model.logout() } }
        }
        .sheet(isPresented: $showsLink, onDismiss: model.dismissAppleLinkOffer) {
            AuthenticationView(viewModel: model)
        }
        .onChange(of: model.shouldOfferAppleLink) { _, showing in
            if !showing { showsLink = false }
        }
        .refreshable { await model.reloadIdentity() }
        .onDisappear { work.cancel() }
    }
}

private struct IdentityPendingEmailView: View {
    let service: IdentityService
    let session: AuthenticationSession
    let model: AuthenticationViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var work = IdentityFormWork()

    var body: some View {
        Form {
            Text("Use an address you can access. This keeps your existing Lenver account.")
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Current password", text: $password).textContentType(.password)
            Button("Update email") {
                work.run(.updateEmail) {
                    let generation = await session.currentGeneration()
                    try await service.changePendingEmail(
                        email: IdentityValidation.normalizedEmail(email), password: password, generation: generation
                    )
                    password = ""
                    await model.reloadIdentity()
                    dismiss()
                }
            }
                    .disabled(!IdentityValidation.isValidEmail(email) || !IdentityValidation.isExistingPassword(password))
            IdentityFeedback(work: work)
        }
        .disabled(work.busy)
        .navigationTitle("Change verification email")
        .onDisappear { work.cancel() }
    }
}

private struct PasswordMethodView: View {
    let service: IdentityService
    let generation: Int
    let model: AuthenticationViewModel
    let removing: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var sent = false
    @State private var work = IdentityFormWork()
    @State private var provider: AppleAuthorizationProvider
    @State private var appleError = false

    init(service: IdentityService, generation: Int, model: AuthenticationViewModel, removing: Bool) {
        self.service = service
        self.generation = generation
        self.model = model
        self.removing = removing
        _provider = State(initialValue: AppleAuthorizationProvider(isEnabled: model.appleAuthorizationAvailable))
    }

    var body: some View {
        let operationID = provider.operationID
        Form {
            if removing {
                Text("You’ll still be able to use the Apple Account linked to Lenver.")
            } else {
                Text("Confirm with Apple, then verify the email you want to add.")
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: email) { _, _ in sent = false; code = "" }
            }
            if model.appleAuthorizationAvailable {
                appleMethodButton(operationID: operationID)
            } else {
                Text("Apple sign-in is unavailable in this build.")
            }

            if appleError { Text("Apple sign-in is temporarily unavailable.") }

            if sent {
                IdentityCodeField(code: $code)
                SecureField("New password", text: $password).textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirmation).textContentType(.newPassword)
                Button("Link email and password") {
                    let submittedEmail = IdentityValidation.normalizedEmail(email)
                    let submittedCode = code
                    let submittedPassword = password
                    work.run(.linkPassword) {
                        try await model.changeIdentityMethod(.linkPassword, generation: generation) { id in
                            try await service.linkPassword(
                                email: submittedEmail, code: submittedCode, password: submittedPassword,
                                operationID: id, generation: generation
                            )
                        }
                        password = ""
                        confirmation = ""
                        await model.reloadIdentity()
                        dismiss()
                    }
                }
                .disabled(work.busy || !model.canChangeMethods || !IdentityValidation.isValidEmail(email) || !code.isIdentityCode || !password.isIdentityPassword || password != confirmation)
            }
            IdentityFeedback(work: work)
            if model.pendingMethodIntent != nil, !model.methodChangeInProgress {
                Button("Back to sign-in methods") { dismiss() }
            }
        }
        .navigationTitle(LocalizedStringKey(removing ? "Unlink email and password" : "Link email and password"))
        .onDisappear {
            provider.cancel(operationID: provider.operationID)
            work.cancel()
        }
    }

    @ViewBuilder
    private func appleMethodButton(operationID: UUID) -> some View {
            SignInWithAppleButton(.continue) { request in
                appleError = false
                do { try provider.configure(request) }
                catch { appleError = true; return }
                work.run(removing ? .unlinkPassword : .requestPasswordLink) {
                    do {
                        let authorization = try await provider.authorization()
                        if removing {
                            try await model.changeIdentityMethod(.unlinkPassword, generation: generation) { id in
                                try await service.unlinkPassword(authorization: authorization, operationID: id, generation: generation)
                            }
                            await model.reloadIdentity()
                            dismiss()
                        } else {
                            try await service.requestPasswordLink(
                                email: IdentityValidation.normalizedEmail(email), authorization: authorization, generation: generation
                            )
                            sent = true
                        }
                    } catch let error as ASAuthorizationError where error.code == .canceled {
                        return
                    }
                }
            } onCompletion: { result in
                provider.complete(result, operationID: operationID)
            }
            .id(operationID)
            .signInWithAppleButtonStyle(.black)
            .frame(height: 44)
            .disabled(work.busy || !model.canChangeMethods || work.resultUnconfirmed || (!removing && !IdentityValidation.isValidEmail(email)))
    }
}

private struct UnlinkAppleView: View {
    let service: IdentityService
    let generation: Int
    let model: AuthenticationViewModel

    @State private var password = ""
    @State private var work = IdentityFormWork()

    var body: some View {
        Form {
            Text("Confirm your Lenver password to remove Apple as a sign-in method.")
            SecureField("Current password", text: $password).textContentType(.password)
                .disabled(work.busy)
            Button("Unlink Apple Account", role: .destructive) {
                let submittedPassword = password
                work.run(.unlinkApple, success: "Apple Account unlinked.") {
                    try await model.changeIdentityMethod(.unlinkApple, generation: generation) { id in
                        try await service.unlinkApple(password: submittedPassword, operationID: id, generation: generation)
                    }
                    password = ""
                    await model.reloadIdentity()
                }
            }
            .disabled(work.busy || !model.canChangeMethods || work.resultUnconfirmed || !IdentityValidation.isExistingPassword(password))
            IdentityFeedback(work: work)
        }
        .navigationTitle("Unlink Apple Account")
        .onDisappear { work.cancel() }
    }
}

private struct IdentityPasswordChangeView: View {
    let service: IdentityService
    let session: AuthenticationSession

    @State private var current = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var pending: UUID?
    @State private var work = IdentityFormWork()

    var body: some View {
        Form {
            if let pending {
                Text("The password change could not be confirmed. Check its status before trying again.")
                Button("Check password change") {
                    work.run(.checkPasswordChange) {
                        let generation = await session.currentGeneration()
                        if try await service.changeCommitted(id: pending, generation: generation) {
                            self.pending = nil
                            work.feedback = "Password updated."
                        } else {
                            work.feedback = "The result is still unknown."
                        }
                    }
                }
                Button("Dismiss this request", role: .cancel) { self.pending = nil }
            } else {
                SecureField("Current password", text: $current).textContentType(.password)
                SecureField("New password", text: $password).textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirmation).textContentType(.newPassword)
                Button("Save password") { changePassword() }
                    .disabled(!IdentityValidation.isExistingPassword(current) || !IdentityValidation.isNewPassword(password) || password != confirmation)
            }
            IdentityFeedback(work: work)
        }
        .disabled(work.busy)
        .navigationTitle("Change password")
        .onDisappear { work.cancel() }
    }

    private func changePassword() {
        work.run(.passwordChange, success: "Password updated.") {
            let generation = await session.currentGeneration()
            let id = UUID()
            defer {
                current = ""
                password = ""
                confirmation = ""
            }
            let proof = try await service.prepareChange(id: id, password: current, generation: generation)
            do {
                try await service.changePassword(id: id, proof: proof, password: password, generation: generation)
            } catch let error as APIError {
                switch error {
                case .transport, .server, .invalidResponse:
                    pending = id
                    throw error
                default:
                    throw error
                }
            }
        }
    }
}

private struct IdentityCodeField: View {
    @Binding var code: String

    var body: some View {
        TextField("Six-digit code", text: $code)
            .textContentType(.oneTimeCode)
            .keyboardType(.numberPad)
            .accessibilityIdentifier("identity.code")
            .onChange(of: code) { _, value in
                code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
            }
    }
}

private struct IdentityFeedback: View {
    let work: IdentityFormWork
    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        if work.busy { ProgressView(work.loadingMessage) }
        if let feedback = work.feedback {
            Text(feedback)
                .accessibilityFocused($focused)
                .onAppear { focused = true }
                .onChange(of: feedback) { _, _ in focused = true }
        }
    }
}

@Observable
private final class IdentityFormWork {
    private var task: Task<Void, Never>?
    var busy: Bool { task != nil }
    var feedback: LocalizedStringResource?
    private(set) var resultUnconfirmed = false
    private(set) var loadingMessage: LocalizedStringResource = "Please wait…"

    func run(
        _ operation: IdentityOperation,
        success: LocalizedStringResource? = nil,
        _ action: @escaping @MainActor () async throws -> Void
    ) {
        guard task == nil, !resultUnconfirmed else { return }
        feedback = nil
        loadingMessage = operation.loadingMessage
        task = Task {
            defer { task = nil }
            do {
                try await action()
                try Task.checkCancellation()
                if let success { feedback = success }
            } catch is CancellationError {
                return
            } catch let error as APIError {
                if operation.blocksAfterUnconfirmedResult, Self.mayHaveCommitted(error) {
                    resultUnconfirmed = true
                    feedback = operation.unknownResultMessage
                } else if case let .rateLimited(retryAfter) = error {
                    feedback = operation.rateLimitedMessage(retryAfter)
                } else if case .http(statusCode: 429, message: _) = error {
                    feedback = operation.rateLimitedMessage(nil)
                } else if Self.isDefinitiveRejection(error) {
                    feedback = operation.rejectedMessage
                } else {
                    feedback = operation.failureMessage
                }
            } catch {
                feedback = operation.failureMessage
            }
        }
    }

    func cancel() { task?.cancel() }

    private static func mayHaveCommitted(_ error: APIError) -> Bool {
        switch error {
        case .transport, .invalidResponse, .server: true
        case .http(statusCode: 500...599, message: _): true
        default: false
        }
    }

    private static func isDefinitiveRejection(_ error: APIError) -> Bool {
        switch error {
        case .badRequest, .unauthorized, .idempotencyConflict, .mvpConflict,
             .http(statusCode: 403, message: _): true
        default: false
        }
    }
}

private enum IdentityOperation {
    case verifyEmail, checkStatus, sendVerification, recoveryRequest, recoverPassword
    case updateEmail, linkApple, requestPasswordLink, unlinkPassword, linkPassword, unlinkApple
    case passwordChange, checkPasswordChange

    var loadingMessage: LocalizedStringResource {
        switch self {
        case .verifyEmail: "Checking verification code…"
        case .checkStatus: "Checking account status…"
        case .sendVerification: "Sending verification code…"
        case .recoveryRequest: "Requesting password recovery…"
        case .recoverPassword: "Updating password…"
        case .updateEmail: "Changing verification email…"
        case .linkApple: "Preparing Apple link…"
        case .requestPasswordLink: "Confirming Apple Account…"
        case .unlinkPassword: "Removing email and password…"
        case .linkPassword: "Linking email and password…"
        case .unlinkApple: "Removing Apple Account…"
        case .passwordChange: "Updating password…"
        case .checkPasswordChange: "Checking password change…"
        }
    }

    var rejectedMessage: LocalizedStringResource {
        switch self {
        case .verifyEmail: "That verification code could not be accepted. Check the code and try again."
        case .checkStatus: "Your account status could not be checked."
        case .sendVerification: "The verification code could not be sent. Try again."
        case .recoveryRequest: "If your account is eligible, it will receive recovery instructions."
        case .recoverPassword: "The code or new password could not be accepted. Check the code and try again."
        case .updateEmail: "The verification email could not be updated. Check the address and current password."
        case .linkApple: "The Apple link could not be started. Check your current sign-in method."
        case .requestPasswordLink: "The sign-in method change could not be started."
        case .unlinkPassword: "Email and password could not be removed as a sign-in method."
        case .linkPassword: "Email and password could not be linked. Check the code and try again."
        case .unlinkApple: "Apple could not be removed as a sign-in method. Check your current password."
        case .passwordChange: "The password could not be changed. Check your current password and new password."
        case .checkPasswordChange: "The password change status could not be checked."
        }
    }

    var failureMessage: LocalizedStringResource {
        switch self {
        case .recoveryRequest:
            "If your account is eligible, the recovery request could not be confirmed. Check your connection before trying again."
        default:
            "This operation could not be confirmed. Check your connection before trying again."
        }
    }

    var unknownResultMessage: LocalizedStringResource {
        "The sign-in method change could not be confirmed. Keep using your current method and do not repeat it yet."
    }

    var blocksAfterUnconfirmedResult: Bool {
        switch self {
        case .requestPasswordLink, .unlinkPassword, .linkPassword, .unlinkApple: true
        default: false
        }
    }

    func rateLimitedMessage(_ seconds: Int?) -> LocalizedStringResource {
        if let seconds {
            return switch self {
            case .recoveryRequest:
                "If your account is eligible, wait \(seconds) seconds before requesting another recovery code."
            case .verifyEmail:
                "Too many email verification attempts. Try again in \(seconds) seconds."
            case .sendVerification:
                "Too many verification code requests. Try again in \(seconds) seconds."
            case .recoverPassword:
                "Too many password recovery attempts. Try again in \(seconds) seconds."
            case .updateEmail:
                "Too many email change attempts. Try again in \(seconds) seconds."
            case .linkApple, .requestPasswordLink, .unlinkPassword, .linkPassword, .unlinkApple:
                "Too many sign-in method changes. Try again in \(seconds) seconds."
            case .passwordChange, .checkPasswordChange:
                "Too many password change requests. Try again in \(seconds) seconds."
            case .checkStatus:
                "Too many status checks. Try again in \(seconds) seconds."
            }
        }
        return switch self {
        case .recoveryRequest:
            "If your account is eligible, wait before requesting another recovery code."
        case .verifyEmail, .sendVerification:
            "Too many verification attempts. Wait before trying again."
        case .recoverPassword, .passwordChange, .checkPasswordChange:
            "Too many password requests. Wait before trying again."
        case .updateEmail:
            "Too many email change attempts. Wait before trying again."
        case .linkApple, .requestPasswordLink, .unlinkPassword, .linkPassword, .unlinkApple:
            "Too many sign-in method changes. Wait before trying again."
        case .checkStatus:
            "Too many status checks. Wait before trying again."
        }
    }
}

private extension String {
    var isIdentityCode: Bool { IdentityValidation.isVerificationCode(self) }
    var isIdentityPassword: Bool { IdentityValidation.isNewPassword(self) }
}

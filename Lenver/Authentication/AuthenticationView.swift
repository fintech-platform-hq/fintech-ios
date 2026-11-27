import AuthenticationServices
import SwiftUI

struct AuthenticationView: View {
    let viewModel: AuthenticationViewModel
    var identityService: IdentityService? = nil

    @State private var mode: Mode = .login
    @AccessibilityFocusState private var focusedFeedback: Bool

    private enum Mode: String, CaseIterable {
        case login = "Sign In"
        case register = "Register"
    }

    private var feedback: LocalizedStringResource? {
        switch viewModel.linkingState {
        case .authorizing: return "Waiting for Apple authorization…"
        case .submitting: return "Linking Apple Account…"
        case .success: return "Apple Account linked. Your Lenver session is still active."
        case let .failure(_, error): return error.message
        default:
            if case let .failure(error) = viewModel.state { return error.message }
            return nil
        }
    }

    private var needsLinkPassword: Bool {
        guard viewModel.usesIdentityV1 else { return false }
        switch viewModel.linkingState {
        case .offer, .failure: return true
        default: return false
        }
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        let appleOperationID = viewModel.appleOperationID
        let passwordRequired = viewModel.linkingState == .passwordRequired

        NavigationStack {
            Form {
                if passwordRequired {
                    Section {
                        Text("Sign in with your Lenver password to review the Apple link.")
                        Button("Not now") { viewModel.dismissAppleLinkOffer() }
                    }
                }
                if let linkSession = viewModel.linkingState.session {
                    Section {
                        if case .review = viewModel.linkingState {
                            Text("Both methods will open the same Lenver account.")
                            Button("Link Apple Account") { Task { await viewModel.confirmAppleLink() } }
                            Button("Cancel", role: .cancel) { viewModel.dismissAppleLinkOffer() }
                        } else if case .success = viewModel.linkingState {
                            Button("Done") { viewModel.dismissAppleLinkOffer() }
                        } else {
                            LabeledContent("Email", value: linkSession.email)
                            if viewModel.usesIdentityV1 {
                                SecureField("Current password", text: $viewModel.linkPassword)
                                    .textContentType(.password)
                                    .disabled(viewModel.operationInProgress)
                            }
                            Button("Not now") { viewModel.dismissAppleLinkOffer() }
                        }
                        if case .failure(_, .passwordRequired) = viewModel.linkingState {
                            Button("Sign in with email and password") { viewModel.requirePasswordForLink() }
                        }
                    }
                } else {
                    if !passwordRequired {
                        Picker("Action", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { mode in
                                Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(viewModel.operationInProgress)
                    }
                    TextField("Email", text: $viewModel.email)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .disabled(viewModel.operationInProgress)
                    SecureField("Password", text: $viewModel.password)
                        .textContentType(passwordRequired || mode == .login ? .password : .newPassword)
                        .disabled(viewModel.operationInProgress)
                    if mode == .register && !passwordRequired {
                        Text("New passwords must contain 12 to 128 characters.")
                            .font(.footnote)
                    }
                    Button(LocalizedStringKey(passwordRequired ? "Sign In" : mode.rawValue)) {
                        Task {
                            if passwordRequired || mode == .login { await viewModel.login() }
                            else { await viewModel.register() }
                        }
                    }
                    .accessibilityIdentifier("authentication.submit")
                    .disabled(viewModel.operationInProgress)
                }

                if !passwordRequired, viewModel.appleAuthorizationAvailable,
                   viewModel.canStartApple || viewModel.operationInProgress || (needsLinkPassword && !viewModel.appleLinkNeedsReconciliation) {
                    SignInWithAppleButton(.signIn) { request in
                        viewModel.configureAppleRequest(request, operationID: appleOperationID)
                    } onCompletion: { result in
                        viewModel.completeAppleAuthorization(result, operationID: appleOperationID)
                    }
                    .id(appleOperationID)
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 44)
                    .disabled(!viewModel.canStartApple)
                }
                if !passwordRequired, !viewModel.appleAuthorizationAvailable {
                    Text("Sign in with Apple is unavailable in this build.")
                        .font(.footnote)
                }
                if let identityService, mode == .login, viewModel.linkingState.session == nil {
                    Section {
                        NavigationLink("Recover password") { IdentityRecoveryView(service: identityService) }
                        Link("Recover your Apple Account", destination: URL(string: "https://iforgot.apple.com")!)
                    }
                }
                if viewModel.remoteSignOutPending { Text("Pending remote sign-out confirmation.") }
                if let result = viewModel.signOutResult {
                    if !result.localConfirmed { Text("Sign-out storage could not be confirmed.") }
                    if !result.remoteConfirmed { Text("Remote sign-out could not be confirmed.") }
                }
                if viewModel.state == .authenticating {
                    ProgressView(viewModel.authenticationProgress)
                }
                if case .authorizing = viewModel.linkingState { ProgressView().accessibilityHidden(true) }
                if case .submitting = viewModel.linkingState { ProgressView().accessibilityHidden(true) }
                if let feedback {
                    Text(feedback)
                        .accessibilityFocused($focusedFeedback)
                        .accessibilityIdentifier("authenticationFeedback")
                }
            }
            .navigationTitle("Lenver")
            .onChange(of: feedback) { _, value in
                // One focus change per distinct feedback transition; no repeated announcements.
                focusedFeedback = value != nil
            }
        }
        .concealWhenInactive()
    }
}

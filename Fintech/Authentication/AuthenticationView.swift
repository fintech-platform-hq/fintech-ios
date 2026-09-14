import AuthenticationServices
import SwiftUI

struct AuthenticationView: View {
    let viewModel: AuthenticationViewModel

    @State private var mode: Mode = .login
    @AccessibilityFocusState private var focusedFeedback: String?

    private enum Mode: String, CaseIterable {
        case login = "Sign In"
        case register = "Register"
    }

    private var feedback: String? {
        switch viewModel.linkingState {
        case .authorizing: return "Aguardando autorização Apple…"
        case .submitting: return "Vinculando conta Apple…"
        case .success: return "Conta Apple vinculada com sucesso. Sua sessão Fintech foi mantida."
        case let .failure(_, error): return error.message
        default:
            if case let .failure(error) = viewModel.state { return error.message }
            return nil
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
                        Text("Já existe uma conta Fintech. Entre com email e senha para continuar. Depois, você poderá escolher se deseja vincular sua identidade Apple.")
                        Button("Agora não") { viewModel.dismissAppleLinkOffer() }
                    }
                }
                if let linkSession = viewModel.linkingState.session {
                    Section {
                        Text("Vincular sua identidade Apple à conta \(linkSession.email) é opcional. Toque no botão Apple para autorizar o vínculo, ou escolha Agora não.")
                        if case .success = viewModel.linkingState {
                            Button("Concluir") { viewModel.dismissAppleLinkOffer() }
                        } else {
                            Button("Agora não") { viewModel.dismissAppleLinkOffer() }
                        }
                        if case .failure(_, .passwordRequired) = viewModel.linkingState {
                            Button("Entrar com email e senha") { viewModel.requirePasswordForLink() }
                        }
                    }
                } else {
                    if !passwordRequired {
                        Picker("Action", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
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
                    Button(passwordRequired ? "Sign In" : mode.rawValue) {
                        Task {
                            if passwordRequired || mode == .login { await viewModel.login() }
                            else { await viewModel.register() }
                        }
                    }
                    .disabled(viewModel.operationInProgress)
                }

                if !passwordRequired, viewModel.canStartApple || viewModel.operationInProgress {
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
                if viewModel.state == .authenticating {
                    ProgressView("Signing in…")
                }
                if case .authorizing = viewModel.linkingState { ProgressView().accessibilityHidden(true) }
                if case .submitting = viewModel.linkingState { ProgressView().accessibilityHidden(true) }
                if let feedback {
                    Text(feedback)
                        .accessibilityFocused($focusedFeedback, equals: feedback)
                        .accessibilityIdentifier("authenticationFeedback")
                }
            }
            .navigationTitle("Fintech")
            .onChange(of: feedback) { _, value in
                // One focus change per distinct feedback transition; no repeated announcements.
                focusedFeedback = value
            }
        }
    }
}

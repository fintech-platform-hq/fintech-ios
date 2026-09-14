import AuthenticationServices
import SwiftUI

struct AuthenticationView: View {
    let viewModel: AuthenticationViewModel

    @State private var mode: Mode = .login
    @AccessibilityFocusState private var errorFocused: Bool

    private enum Mode: String, CaseIterable {
        case login = "Sign In"
        case register = "Register"
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        let appleOperationID = viewModel.appleOperationID

        NavigationStack {
            Form {
                Picker("Action", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Email", text: $viewModel.email)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()

                SecureField("Password", text: $viewModel.password)
                    .textContentType(mode == .login ? .password : .newPassword)

                Button(mode.rawValue) {
                    Task {
                        if mode == .login {
                            await viewModel.login()
                        } else {
                            await viewModel.register()
                        }
                    }
                }
                .disabled(viewModel.state == .authenticating)

                SignInWithAppleButton(.signIn) { request in
                    viewModel.configureAppleRequest(request, operationID: appleOperationID)
                } onCompletion: { result in
                    viewModel.completeAppleAuthorization(result, operationID: appleOperationID)
                }
                // Keep each native button instance bound to its original authorization.
                .id(appleOperationID)
                .signInWithAppleButtonStyle(.black)
                .frame(height: 44)
                .disabled(viewModel.state == .authenticating)

                if viewModel.state == .authenticating {
                    ProgressView("Signing in…")
                }

                if case let .failure(error) = viewModel.state {
                    Text(error.message)
                        .foregroundStyle(.red)
                        .accessibilityFocused($errorFocused)
                }
            }
            .navigationTitle("Fintech")
            .onChange(of: viewModel.state, initial: true) { _, state in
                if case .failure = state {
                    errorFocused = true
                } else {
                    errorFocused = false
                }
            }
        }
    }
}

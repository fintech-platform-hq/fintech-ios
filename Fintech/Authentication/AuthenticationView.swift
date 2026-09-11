import SwiftUI

struct AuthenticationView: View {
    let viewModel: AuthenticationViewModel

    @State private var mode: Mode = .login

    private enum Mode: String, CaseIterable {
        case login = "Sign In"
        case register = "Register"
    }

    var body: some View {
        @Bindable var viewModel = viewModel

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

                if case let .failure(error) = viewModel.state {
                    Text(error.message)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Fintech")
        }
    }
}

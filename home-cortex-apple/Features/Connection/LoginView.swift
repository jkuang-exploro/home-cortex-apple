import SwiftUI

struct LoginView: View {
    @Bindable var connection: ConnectionController
    @State private var email = ""
    @State private var apiKey = ""
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("老管家").font(.largeTitle.bold())
                    Text("Sign in to Home Cortex").font(.title2)
                        .accessibilityIdentifier("login.title")
                    Text("Use the same email and API key as Home Cortex web.")
                        .foregroundStyle(.secondary)
                    TextField("Email", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("login.email")
                    SecureField("API key", text: $apiKey)
                        .textContentType(.password).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("login.key")
                    Button(connection.signingIn ? "Signing in…" : "Sign in") {
                        let submittedKey = apiKey
                        let submittedEmail = email
                        apiKey = ""
                        Task { await connection.signIn(email: submittedEmail, apiKey: submittedKey) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(connection.signingIn || connection.busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKey.isEmpty)
                    .accessibilityIdentifier("login.submit")
                    if connection.signingIn {
                        ProgressView(connection.provisioning == .notProvisioned ? "Signing in…" : connection.provisioning.label)
                    }
                    if case .failed(let error) = connection.state {
                        Text(error.localizedDescription).foregroundStyle(.red).accessibilityIdentifier("login.error")
                    }
                    Button("Advanced connection setup") { showAdvanced = true }
                        .font(.footnote).disabled(connection.signingIn || connection.busy)
                        .accessibilityIdentifier("login.advanced")
                }.padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
            }
            .navigationTitle("Home Cortex").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAdvanced) {
                NavigationStack {
                    ConnectionView(connection: connection).toolbar { Button("Done") { showAdvanced = false } }
                }
            }
        }
    }
}

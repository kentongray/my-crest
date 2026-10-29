import SwiftUI

/// Whether this device offers an external password manager's logins, which
/// accounts it reads, and whether it can reach them.
struct BrowserExternalCredentialSourceSection: View {
    let source: any BrowserExternalCredentialSource

    @State private var accountsDraft = ""

    var body: some View {
        Section {
            Toggle(
                "Fill from \(source.name)",
                isOn: Binding(get: { source.isEnabled }, set: { source.isEnabled = $0 })
            )
            .accessibilityIdentifier("external-credential-source-enabled")

            if source.isEnabled {
                TextField("Accounts", text: $accountsDraft, prompt: Text("Sign-in addresses or account IDs"))
                    .onSubmit(applyAccounts)
                    .accessibilityIdentifier("external-credential-source-accounts")

                if let message = source.status.message {
                    Label(message, systemImage: source.status.needsAttention ? "exclamationmark.triangle" : "checkmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("Check Connection") {
                    applyAccounts()
                    Task { await source.checkConnection() }
                }
            }
        } header: {
            Text(source.name)
        } footer: {
            Text("Offered beside Crest Passwords in Spaces that use them, on this Mac.")
        }
        .onAppear { accountsDraft = source.accounts }
    }

    private func applyAccounts() {
        source.accounts = accountsDraft
    }
}

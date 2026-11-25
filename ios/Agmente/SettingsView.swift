import SwiftUI

struct SettingsView: View {
    @Binding var devModeEnabled: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Label {
                                Text("Language")
                            } icon: {
                                Image(systemName: "globe")
                            }
                            Spacer()
                            Text(AppLocalization.effectiveLanguageAutonym)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("settings-language-button")
                }

                Section("Developer") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Developer mode", isOn: $devModeEnabled)
                        Text("Shows extra diagnostics like connection status on server cards.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    SettingsView(devModeEnabled: .constant(true))
}

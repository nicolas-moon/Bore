import SwiftUI

/// The Settings window (Cmd+,). Edits persist immediately; host/port changes are applied
/// the next time the tunnel connects.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var tunnel: TunnelManager

    /// True when the running tunnel was started with different host/port than now configured.
    private var hasPendingTunnelChanges: Bool {
        (tunnel.state.isConnected || tunnel.state.isConnecting)
            && settings.isValid
            && tunnel.configuration != settings.tunnelConfiguration
    }

    var body: some View {
        Form {
            Section("Tunnel") {
                TextField("SSH host", text: $settings.host, prompt: Text("alias or user@hostname"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                if !settings.isHostValid {
                    validationLabel("Enter a host alias from ~/.ssh/config or user@hostname.")
                } else {
                    caption("Resolved by ssh using your ~/.ssh/config, agent, and known_hosts.")
                }

                TextField("SOCKS port", value: $settings.socksPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                if !settings.isPortValid {
                    validationLabel("Port must be between 1 and 65535.")
                } else {
                    caption("Bore listens on 127.0.0.1:\(String(settings.socksPort)).")
                }

                if hasPendingTunnelChanges {
                    Label("Changes apply the next time you connect.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Behavior") {
                Toggle("Reconnect automatically after an unexpected disconnect", isOn: $settings.autoReconnect)
                    .onChange(of: settings.autoReconnect) { _, enabled in
                        if !enabled { tunnel.cancelPendingReconnect() }
                    }
                Toggle("Connect when Bore launches", isOn: $settings.connectAtLaunch)
                Toggle("Launch Bore at login", isOn: $settings.launchAtLogin)
                if let error = settings.launchAtLoginError {
                    validationLabel(error)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { settings.refreshLaunchAtLogin() }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func validationLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}

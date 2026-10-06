import SwiftUI

/// Menu bar icon. Kept as its own view so it re-renders when the tunnel state changes.
struct MenuBarLabel: View {
    @ObservedObject var tunnel: TunnelManager

    var body: some View {
        Image(systemName: tunnel.state.symbolName)
    }
}

/// The dropdown menu. Intentionally small: status, one primary action, Settings, Quit.
struct MenuBarView: View {
    @ObservedObject var tunnel: TunnelManager
    @ObservedObject var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    /// While a tunnel is up (or coming up) show what it was actually started with;
    /// otherwise show what the next connect will use.
    private var displayedConfiguration: TunnelConfiguration {
        if tunnel.state.isConnected || tunnel.state.isConnecting {
            return tunnel.configuration
        }
        return settings.tunnelConfiguration
    }

    private var route: String {
        "\(displayedConfiguration.host) → \(displayedConfiguration.socksEndpoint)"
    }

    private var hasPendingTunnelChanges: Bool {
        tunnel.state.isConnected
            && settings.isValid
            && tunnel.configuration != settings.tunnelConfiguration
    }

    var body: some View {
        Text("Bore")

        switch tunnel.state {
        case .disconnected:
            Text("○ Disconnected")
            if let message = settings.validationMessage {
                Text(message)
            } else {
                Text(route)
            }
            Button("Connect") { tunnel.connect() }
                .disabled(!settings.isValid)

        case .connecting:
            Text(tunnel.isReconnecting ? "◌ Reconnecting…" : "◌ Connecting…")
            Text(route)
            Button("Cancel") { tunnel.disconnect() }

        case .connected:
            Text("● Connected")
            Text(route)
            if hasPendingTunnelChanges {
                Text("Settings changed; reconnect to apply")
            }
            Button("Disconnect") { tunnel.disconnect() }

        case .failed(let failure):
            Text(tunnel.nextReconnectDate == nil ? "⚠ Connection Failed" : "⚠ Connection Lost")
            Text(failure.summary)
            if let next = tunnel.nextReconnectDate {
                Text("Retrying in \(next, style: .relative)")
                Button("Retry Now") { tunnel.retry() }
                Button("Disconnect") { tunnel.disconnect() }
            } else {
                Button("Retry") { tunnel.retry() }
                    .disabled(!settings.isValid)
            }
        }

        Divider()

        Button("Settings…") {
            // Menu-bar-only apps are never "active", so the window would otherwise open behind others.
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Open Logs") {
            // Opens in Console.app (the default handler for .log files).
            NSWorkspace.shared.open(FileLog.shared.fileURL)
        }

        Button("Quit Bore") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

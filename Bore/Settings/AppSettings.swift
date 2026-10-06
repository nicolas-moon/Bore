import Foundation
import ServiceManagement

private let log = BoreLogger(category: "settings")

/// User-editable settings, persisted in `UserDefaults`.
///
/// Tunnel-related values (host, port) are read by `TunnelManager` when a connection attempt
/// starts, so edits made while connected take effect on the next connect or reconnect.
/// Behavioral toggles (auto-reconnect) are read at the moment they matter and apply immediately.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let host = "sshHost"
        static let socksPort = "socksPort"
        static let autoReconnect = "autoReconnect"
        static let connectAtLaunch = "connectAtLaunch"
    }

    nonisolated static let defaultHost = "nmoon-moose"
    nonisolated static let defaultSocksPort = 1080
    nonisolated static let portRange = 1...65535

    private let defaults: UserDefaults

    @Published var host: String {
        didSet { defaults.set(host, forKey: Key.host) }
    }

    @Published var socksPort: Int {
        didSet { defaults.set(socksPort, forKey: Key.socksPort) }
    }

    @Published var autoReconnect: Bool {
        didSet { defaults.set(autoReconnect, forKey: Key.autoReconnect) }
    }

    @Published var connectAtLaunch: Bool {
        didSet { defaults.set(connectAtLaunch, forKey: Key.connectAtLaunch) }
    }

    /// Mirrors `SMAppService.mainApp` rather than UserDefaults: the system is the source of truth.
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin, launchAtLogin != oldValue else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    /// Set when registering/unregistering the login item fails; shown in Settings.
    @Published private(set) var launchAtLoginError: String?

    private var isSyncingLaunchAtLogin = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.host: Self.defaultHost,
            Key.socksPort: Self.defaultSocksPort,
            Key.autoReconnect: true,
            Key.connectAtLaunch: false,
        ])

        host = defaults.string(forKey: Key.host) ?? Self.defaultHost
        socksPort = defaults.integer(forKey: Key.socksPort)
        autoReconnect = defaults.bool(forKey: Key.autoReconnect)
        connectAtLaunch = defaults.bool(forKey: Key.connectAtLaunch)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Validation

    var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Non-empty, no whitespace, and not something ssh would parse as an option.
    var isHostValid: Bool {
        let value = trimmedHost
        return !value.isEmpty
            && !value.hasPrefix("-")
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    var isPortValid: Bool {
        Self.portRange.contains(socksPort)
    }

    var isValid: Bool {
        isHostValid && isPortValid
    }

    /// Why the current settings cannot be used to connect, or nil if they can.
    var validationMessage: String? {
        if !isHostValid { return "Set an SSH host in Settings." }
        if !isPortValid { return "SOCKS port must be between 1 and 65535." }
        return nil
    }

    /// Snapshot of the tunnel configuration as currently configured.
    /// Callers should check `isValid` first; invalid values fall back to defaults here.
    var tunnelConfiguration: TunnelConfiguration {
        var configuration = TunnelConfiguration()
        configuration.host = isHostValid ? trimmedHost : Self.defaultHost
        configuration.socksPort = isPortValid ? UInt16(socksPort) : UInt16(Self.defaultSocksPort)
        return configuration
    }

    // MARK: - Launch at login

    /// Re-reads the login item status; call when the Settings window appears in case the
    /// user changed it in System Settings.
    func refreshLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin {
            isSyncingLaunchAtLogin = true
            launchAtLogin = enabled
            isSyncingLaunchAtLogin = false
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                log.notice("Launch at login enabled")
            } else {
                try SMAppService.mainApp.unregister()
                log.notice("Launch at login disabled")
            }
            launchAtLoginError = nil
        } catch {
            log.error("Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)")
            launchAtLoginError = error.localizedDescription
            isSyncingLaunchAtLogin = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            isSyncingLaunchAtLogin = false
        }

        if SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginError = "Approve Bore under System Settings › General › Login Items."
        }
    }
}

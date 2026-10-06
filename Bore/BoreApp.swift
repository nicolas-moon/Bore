import AppKit
import OSLog
import SwiftUI

private let log = BoreLogger(category: "app")

@main
struct BoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(tunnel: appDelegate.tunnel, settings: appDelegate.settings)
        } label: {
            MenuBarLabel(tunnel: appDelegate.tunnel)
        }

        Settings {
            SettingsView(settings: appDelegate.settings, tunnel: appDelegate.tunnel)
        }
    }
}

/// Owns settings and the single `TunnelManager`, and guarantees the SSH process is torn down when Bore quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings: AppSettings
    let tunnel: TunnelManager

    override init() {
        settings = AppSettings()
        tunnel = TunnelManager(settings: settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        log.notice("Bore \(version) (\(build)) launched; log file: \(FileLog.shared.fileURL.path)")
        let configuration = settings.tunnelConfiguration
        log.notice("Configured tunnel: \(configuration.host) → \(configuration.socksEndpoint); autoReconnect=\(settings.autoReconnect) connectAtLaunch=\(settings.connectAtLaunch) launchAtLogin=\(settings.launchAtLogin)")

        if settings.connectAtLaunch {
            log.notice("Connecting at launch (enabled in Settings)")
            tunnel.connect()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.notice("Bore quitting")
        tunnel.shutdown()
        FileLog.shared.flush()
    }
}

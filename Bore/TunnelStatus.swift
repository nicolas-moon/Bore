import Foundation

/// What the user wants the tunnel to be doing.
enum DesiredState: Equatable {
    case connected
    case disconnected
}

/// What the tunnel is actually doing.
enum TunnelState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(TunnelFailure)

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    var isConnected: Bool {
        self == .connected
    }

    var failure: TunnelFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    /// SF Symbol used for the menu bar icon.
    var symbolName: String {
        switch self {
        case .disconnected: return "network.slash"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected: return "network"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

/// A concise, user-presentable description of why the tunnel is not up.
/// `detail` retains the raw SSH stderr for diagnostics and is never shown in the menu.
struct TunnelFailure: Equatable {
    let summary: String
    let detail: String

    init(summary: String, detail: String = "") {
        self.summary = summary
        self.detail = detail
    }

    /// Maps raw SSH stderr and an exit status to a short message suitable for the menu.
    static func fromSSHExit(stderr: String, status: Int32, reason: Process.TerminationReason) -> TunnelFailure {
        let patterns: [(needle: String, summary: String)] = [
            ("Permission denied", "Permission denied (publickey)."),
            ("Host key verification failed", "Host key verification failed."),
            ("REMOTE HOST IDENTIFICATION HAS CHANGED", "Remote host key has changed."),
            ("Could not resolve hostname", "Could not resolve hostname."),
            ("Address already in use", "Address already in use."),
            ("Could not request local forwarding", "Could not bind the SOCKS port."),
            ("Connection refused", "Connection refused."),
            ("Connection timed out", "Connection timed out."),
            ("Operation timed out", "Connection timed out."),
            ("Timeout, server", "Server stopped responding."),
            ("No route to host", "No route to host."),
            ("Network is unreachable", "Network is unreachable."),
            ("Network is down", "Network is down."),
            ("closed by remote host", "Connection closed by remote host."),
            ("Connection reset by peer", "Connection reset by peer."),
            ("Broken pipe", "Connection lost."),
            ("Too many authentication failures", "Too many authentication failures."),
            ("No such file or directory", "SSH configuration error."),
            ("Bad configuration option", "Invalid SSH configuration."),
        ]

        for pattern in patterns where stderr.localizedCaseInsensitiveContains(pattern.needle) {
            return TunnelFailure(summary: pattern.summary, detail: stderr)
        }

        if let lastLine = stderr
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }) {
            var line = lastLine
            if line.hasPrefix("ssh: ") { line.removeFirst(5) }
            if line.count > 80 { line = String(line.prefix(77)) + "…" }
            return TunnelFailure(summary: line, detail: stderr)
        }

        switch reason {
        case .uncaughtSignal:
            return TunnelFailure(summary: "SSH was terminated (signal \(status)).", detail: stderr)
        default:
            return TunnelFailure(summary: "SSH exited with status \(status).", detail: stderr)
        }
    }
}

/// Everything needed to launch one SSH tunnel. `host` and `socksPort` come from `AppSettings`;
/// the rest are fixed. `TunnelManager` snapshots one of these per connection attempt.
struct TunnelConfiguration: Equatable {
    var sshPath = "/usr/bin/ssh"
    var host = AppSettings.defaultHost
    var socksAddress = "127.0.0.1"
    var socksPort: UInt16 = UInt16(AppSettings.defaultSocksPort)

    /// How long to wait for the SOCKS listener after launching SSH before giving up.
    var connectTimeout: TimeInterval = 30

    /// How long to wait for SSH to exit after SIGTERM before sending SIGKILL.
    var terminationGracePeriod: TimeInterval = 2

    /// Backoff schedule for automatic reconnection. The last value repeats.
    var reconnectDelays: [TimeInterval] = [2, 5, 10, 30, 60]

    var socksEndpoint: String {
        "\(socksAddress):\(socksPort)"
    }

    var sshArguments: [String] {
        [
            "-D", socksEndpoint,
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            host,
        ]
    }
}

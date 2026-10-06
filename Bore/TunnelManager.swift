import Foundation
import Network
import OSLog

private let log = BoreLogger(category: "tunnel")

/// Owns the lifecycle of the single SSH process Bore manages and exposes observable tunnel state.
///
/// Every connection attempt is tagged with an `Attempt` token. Callbacks from the process,
/// the stderr reader, and the listener probe all carry their token and are ignored if they
/// no longer refer to the current attempt. This is what makes Retry/Disconnect/unexpected-exit
/// safe to interleave without stale callbacks corrupting state.
@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var state: TunnelState = .disconnected
    @Published private(set) var desiredState: DesiredState = .disconnected

    /// True while `state == .connecting` as part of an automatic reconnect rather than a user action.
    @Published private(set) var isReconnecting = false

    /// Set while a reconnect is scheduled; the UI uses it to show "Reconnecting in Ns…".
    @Published private(set) var nextReconnectDate: Date?

    /// Configuration snapshot taken when the current (or most recent) attempt started.
    /// Settings edits do not affect a running tunnel; they are picked up by the next attempt.
    @Published private(set) var configuration: TunnelConfiguration

    private let settings: AppSettings

    /// Raw stderr from the most recent SSH process, kept for diagnostics only.
    private(set) var lastStderr = ""

    private final class Attempt {
        let id = UUID()
        let process = Process()
        let isAutomatic: Bool
        var stderr = ""
        var stderrReader: Task<Void, Never>?
        var listenerProbe: Task<Void, Never>?
        var reachedConnected = false

        init(isAutomatic: Bool) {
            self.isAutomatic = isAutomatic
        }
    }

    private var attempt: Attempt?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectFailures = 0

    init(settings: AppSettings) {
        self.settings = settings
        self.configuration = settings.tunnelConfiguration
    }

    // MARK: - User actions

    func connect() {
        log.notice("Tunnel connection requested")
        desiredState = .connected
        cancelScheduledReconnect()
        reconnectFailures = 0
        Task { await startAttempt(isAutomatic: false) }
    }

    func disconnect() {
        log.notice("Tunnel disconnected by user")
        desiredState = .disconnected
        cancelScheduledReconnect()
        isReconnecting = false

        if let current = attempt {
            attempt = nil
            current.listenerProbe?.cancel()
            Task { await terminate(current.process) }
        }

        state = .disconnected
    }

    func retry() {
        connect()
    }

    /// Synchronously tears down the SSH process. Called from `applicationWillTerminate`,
    /// where there is no opportunity to await anything.
    func shutdown() {
        desiredState = .disconnected
        cancelScheduledReconnect()
        guard let current = attempt else { return }
        attempt = nil
        current.listenerProbe?.cancel()

        let process = current.process
        guard process.isRunning else { return }
        log.notice("Tunnel terminated during Bore shutdown (pid \(process.processIdentifier))")
        process.terminate()

        let deadline = Date().addingTimeInterval(configuration.terminationGracePeriod)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            log.warning("SSH did not exit after SIGTERM during shutdown; sending SIGKILL")
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Connection attempt

    private func startAttempt(isAutomatic: Bool) async {
        // Retry must fully clean up any previous process before launching another.
        if let previous = attempt {
            attempt = nil
            previous.listenerProbe?.cancel()
            await terminate(previous.process)
        }

        guard desiredState == .connected else { return }

        isReconnecting = isAutomatic
        nextReconnectDate = nil
        state = .connecting

        // Pick up any settings edits made since the last attempt.
        guard settings.isValid else {
            let message = settings.validationMessage ?? "Settings are invalid."
            log.error("Cannot connect: \(message)")
            fail(TunnelFailure(summary: message), attempt: nil, isAutomatic: isAutomatic)
            return
        }
        configuration = settings.tunnelConfiguration

        // If something else already owns the port, SSH would exit via ExitOnForwardFailure,
        // but a probe might race ahead of that and report the foreign listener as ours.
        if await probeListener() {
            log.error("SOCKS port \(self.configuration.socksEndpoint) is already in use before launching SSH")
            fail(TunnelFailure(summary: "Address already in use."), attempt: nil, isAutomatic: isAutomatic)
            return
        }

        let current = Attempt(isAutomatic: isAutomatic)
        let process = current.process
        process.executableURL = URL(fileURLWithPath: configuration.sshPath)
        process.arguments = configuration.sshArguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let attemptID = current.id
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            let reason = process.terminationReason
            Task { @MainActor [weak self] in
                await self?.handleExit(attemptID: attemptID, status: status, reason: reason)
            }
        }

        do {
            try process.run()
        } catch {
            log.error("Failed to launch ssh: \(error.localizedDescription)")
            fail(TunnelFailure(summary: "Could not launch /usr/bin/ssh.", detail: error.localizedDescription),
                 attempt: nil, isAutomatic: isAutomatic)
            return
        }

        attempt = current
        let command = ([configuration.sshPath] + configuration.sshArguments).joined(separator: " ")
        log.notice("SSH process launched (pid \(process.processIdentifier)): \(command)")

        current.stderrReader = Task.detached { [weak self] in
            let handle = stderrPipe.fileHandleForReading
            do {
                for try await line in handle.bytes.lines {
                    await self?.appendStderr(line, attemptID: attemptID)
                }
            } catch {
                // Reading stops when the pipe closes; nothing to do.
            }
        }

        current.listenerProbe = Task { [weak self] in
            await self?.waitForListener(attemptID: attemptID)
        }
    }

    private func appendStderr(_ line: String, attemptID: UUID) {
        guard let current = attempt, current.id == attemptID else { return }
        current.stderr += line + "\n"
        lastStderr = current.stderr
        log.ssh(line)
    }

    private func waitForListener(attemptID: UUID) async {
        let deadline = Date().addingTimeInterval(configuration.connectTimeout)

        while Date() < deadline, !Task.isCancelled {
            guard let current = attempt, current.id == attemptID else { return }

            if await probeListener() {
                guard let current = attempt, current.id == attemptID, current.process.isRunning else { return }
                log.notice("SOCKS listener detected on \(self.configuration.socksEndpoint)")
                current.reachedConnected = true
                reconnectFailures = 0
                isReconnecting = false
                state = .connected
                log.notice("Tunnel connected")
                return
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        guard !Task.isCancelled, let current = attempt, current.id == attemptID else { return }
        log.error("Timed out waiting for SOCKS listener")
        attempt = nil
        let isAutomatic = current.isAutomatic
        await terminate(current.process)
        fail(TunnelFailure(summary: "Timed out waiting for SSH.", detail: current.stderr),
             attempt: current, isAutomatic: isAutomatic)
    }

    private func handleExit(attemptID: UUID, status: Int32, reason: Process.TerminationReason) async {
        guard let current = attempt, current.id == attemptID else {
            // Either an intentional disconnect already cleared this attempt, or it is stale.
            return
        }

        attempt = nil
        current.listenerProbe?.cancel()

        // Give the stderr reader a moment to drain so the failure summary sees the final lines.
        if let reader = current.stderrReader {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await reader.value }
                group.addTask { try? await Task.sleep(for: .milliseconds(500)) }
                await group.next()
                group.cancelAll()
            }
        }

        log.notice("SSH process exited (status \(status))")

        guard desiredState == .connected else {
            state = .disconnected
            return
        }

        log.error("Unexpected disconnect detected")
        let failure = TunnelFailure.fromSSHExit(stderr: current.stderr, status: status, reason: reason)
        fail(failure, attempt: current, isAutomatic: current.isAutomatic)
    }

    /// Transitions to `.failed` and decides whether to schedule an automatic reconnect.
    ///
    /// Reconnect is attempted when the tunnel had been established and then dropped, or when
    /// an automatic attempt failed (so backoff keeps going). A user-initiated attempt that
    /// never connected is abandoned; the user sees the error and can Retry.
    private func fail(_ failure: TunnelFailure, attempt: Attempt?, isAutomatic: Bool) {
        isReconnecting = false
        state = .failed(failure)
        log.error("Tunnel failed: \(failure.summary)")

        let shouldReconnect = settings.autoReconnect
            && desiredState == .connected
            && (isAutomatic || attempt?.reachedConnected == true)

        if shouldReconnect {
            scheduleReconnect()
        } else {
            desiredState = .disconnected
        }
    }

    // MARK: - Automatic reconnect

    private func scheduleReconnect() {
        cancelScheduledReconnect()

        let delays = configuration.reconnectDelays
        let delay = delays[min(reconnectFailures, delays.count - 1)]
        reconnectFailures += 1

        let fireDate = Date().addingTimeInterval(delay)
        nextReconnectDate = fireDate
        log.notice("Reconnect scheduled in \(Int(delay))s (failure #\(self.reconnectFailures))")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard self.desiredState == .connected else { return }
            guard self.settings.autoReconnect else {
                self.cancelPendingReconnect()
                return
            }
            log.notice("Reconnect attempted")
            self.nextReconnectDate = nil
            await self.startAttempt(isAutomatic: true)
        }
    }

    /// Abandons a scheduled reconnect, leaving the current failure visible with a Retry action.
    /// Called when the user turns off automatic reconnect while one is pending.
    func cancelPendingReconnect() {
        guard nextReconnectDate != nil else { return }
        log.notice("Pending reconnect cancelled (automatic reconnect disabled)")
        cancelScheduledReconnect()
        desiredState = .disconnected
    }

    private func cancelScheduledReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        nextReconnectDate = nil
    }

    // MARK: - Process termination

    /// SIGTERM the process, wait briefly, then SIGKILL if it is still running.
    private func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        log.notice("Terminating SSH process (pid \(pid))")
        process.terminate()

        let deadline = Date().addingTimeInterval(configuration.terminationGracePeriod)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if process.isRunning {
            log.warning("SSH (pid \(pid)) did not exit after SIGTERM; sending SIGKILL")
            kill(pid, SIGKILL)
        }
    }

    // MARK: - Listener probe

    /// Attempts a TCP connection to the SOCKS address. Resolves `true` only if the connect succeeds.
    private func probeListener(timeout: TimeInterval = 1) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: configuration.socksPort) else { return false }
        let host = NWEndpoint.Host(configuration.socksAddress)

        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.nmoon.Bore.probe")
            let connection = NWConnection(host: host, port: port, using: .tcp)
            var finished = false

            // Only ever called on `queue`, so `finished` needs no further synchronization.
            let finish: (Bool) -> Void = { result in
                guard !finished else { return }
                finished = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .waiting, .cancelled:
                    finish(false)
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }

            connection.start(queue: queue)
        }
    }
}

# Bore

Bore is a lightweight native macOS menu bar application for managing a local SOCKS5 proxy over SSH.

It replaces repeatedly running:

```text
ssh -D 1080 -N nmoon-moose
```

with a simple menu bar toggle.

Bore should be intentionally small, native, reliable, and focused on doing one thing well.

> **Bore — a tiny SSH tunnel for macOS.**

---

## Goal

Provide a macOS menu bar application that allows the user to:

- Start an SSH SOCKS proxy to `nmoon-moose`.
- Stop the proxy.
- Immediately see whether the tunnel is connected.
- Detect when the SSH connection unexpectedly dies.
- See useful connection errors.
- Run entirely from the macOS menu bar.
- Avoid displaying a normal application window or Dock icon.

The initial version should **not** attempt to become a generic SSH tunnel manager.

Default configuration:

```text
SSH Host: nmoon-moose
SOCKS Address: 127.0.0.1
SOCKS Port: 1080
```

---

# Technology

Build Bore using:

- Swift
- SwiftUI
- macOS `MenuBarExtra`
- Foundation `Process`
- Apple's Network framework where appropriate
- `OSLog`
- ServiceManagement for optional launch-at-login support

Target a modern macOS version where `MenuBarExtra` is available.

Avoid third-party dependencies unless there is a compelling technical reason to introduce one.

---

# Building and Running

Bore is a plain Swift Package (`Package.swift`) with no Xcode project. It requires macOS 14+ and the Swift toolchain that ships with the Command Line Tools or Xcode.

```sh
./build.sh          # release build -> dist/Bore.app (ad-hoc signed)
./build.sh --run    # build, quit any running instance, then launch
./build.sh --debug  # debug build instead of release
```

`build.sh` runs `swift build`, assembles `dist/Bore.app` from `Support/Info.plist` and the built binary, and signs it with `codesign --sign -`. The app is menu-bar-only (`LSUIElement`), so nothing appears in the Dock.

To tail Bore's logs:

```sh
/usr/bin/log stream --predicate 'subsystem == "com.nmoon.Bore"' --style compact
```

(`/usr/bin/log` is spelled out because `log` is a zsh builtin.)

---

# Project Structure

Keep the project small and easy to understand.

Current organization:

```text
Bore/
├── BoreApp.swift          App entry, AppDelegate (owns AppSettings + TunnelManager), quit cleanup
├── BoreLog.swift          FileLog + BoreLogger (OSLog + ~/Library/Logs/Bore/Bore.log)
├── MenuBarView.swift      Menu bar icon + dropdown
├── TunnelManager.swift    SSH process lifecycle, listener probe, reconnect backoff
├── TunnelStatus.swift     TunnelState / TunnelFailure / TunnelConfiguration
└── Settings/
    ├── AppSettings.swift  UserDefaults-backed settings + validation + launch-at-login
    └── SettingsView.swift Settings window (Cmd+,)
```

Do not introduce unnecessary architecture, dependency injection frameworks, networking abstractions, or persistence layers.

`TunnelManager` should own the lifecycle of the SSH process and expose observable tunnel state to the UI.

---

# SSH Tunnel

Bore should execute the system OpenSSH client located at:

```text
/usr/bin/ssh
```

The resulting SSH invocation should be equivalent to:

```text
/usr/bin/ssh \
    -D 127.0.0.1:1080 \
    -N \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    nmoon-moose
```

Important requirements:

- Bind the SOCKS proxy specifically to `127.0.0.1`.
- Do not expose the SOCKS listener to the LAN.
- Use `ExitOnForwardFailure=yes`.
- Use SSH keepalives so dead connections can be detected.
- Do not execute SSH through a shell unless absolutely necessary.
- Launch `/usr/bin/ssh` directly with arguments.

---

# SSH Configuration

Do **not** implement SSH authentication inside Bore.

Bore should rely entirely on the user's existing OpenSSH environment, including:

```text
~/.ssh/config
SSH aliases
IdentityFile
ProxyJump
ssh-agent
macOS Keychain integration
known_hosts
```

The hostname:

```text
nmoon-moose
```

should be passed directly to SSH exactly as it would be from Terminal.

If this works:

```text
ssh -D 1080 -N nmoon-moose
```

Bore should use the same underlying SSH configuration.

Bore must not:

- Copy SSH keys.
- Import SSH keys.
- Store private keys.
- Generate SSH keys.
- Manage SSH passwords.
- Disable host-key verification.

---

# Tunnel State

Represent the tunnel using clear application states:

```text
Disconnected
Connecting
Connected
Failed
```

`Failed` should contain enough information to present a useful error message.

The application should also internally distinguish between:

```text
Desired State
Actual State
```

For example:

```text
desiredState = connected
actualState = connecting
```

This becomes important for automatic reconnection.

Bore should never report `Connected` merely because the SSH process successfully launched.

Connection flow:

```text
Disconnected
     ↓
User selects Connect
     ↓
Connecting
     ↓
Launch SSH
     ↓
Verify SSH remains alive
     ↓
Verify 127.0.0.1:1080
     ↓
Connected
```

Failure at any point should transition to `Failed`.

---

# Connection Verification

After starting SSH, verify that the local SOCKS listener actually becomes available.

Check:

```text
127.0.0.1:1080
```

Prefer Apple's Network framework rather than shelling out to utilities such as:

```text
lsof
nc
curl
```

Use a reasonable timeout.

Do not leave Bore indefinitely in the `Connecting` state.

If SSH exits before the listener becomes available, surface the SSH failure.

---

# Process Management

Bore must only manage SSH processes that Bore starts.

Never use broad commands such as:

```text
pkill ssh
killall ssh
```

Store and manage the specific running `Process` instance and PID.

When disconnecting:

1. Mark the disconnect as intentional.
2. Disable reconnect behavior.
3. Request termination of the managed SSH process.
4. Wait briefly for clean termination.
5. Force termination only if necessary.
6. Transition to `Disconnected`.

When Bore quits, terminate any SSH process it owns.

Do not leave orphaned SSH tunnels running after Bore exits.

Do not interfere with unrelated SSH sessions.

---

# Error Handling

Capture SSH stderr.

Errors should be surfaced through the menu bar when useful.

Examples include:

```text
Permission denied (publickey).
```

```text
Connection refused
```

```text
Could not resolve hostname
```

```text
Address already in use
```

```text
Host key verification failed
```

The normal menu UI should display a concise error rather than dumping the entire SSH output.

The most recent SSH stderr can be retained internally for diagnostics.

---

# Menu Bar UI

Bore should be a menu-bar-only application.

There should be:

- No normal application window.
- No Dock icon during normal operation.
- No unnecessary onboarding flow.

The menu bar icon should communicate tunnel state.

Conceptually:

```text
Disconnected → inactive tunnel icon
Connecting   → transitional icon
Connected    → active tunnel icon
Failed       → warning icon
```

Use appropriate SF Symbols.

The menu should remain intentionally small. The layouts below show the state-specific part; every state is followed by a divider and `Settings…`, `Open Logs`, `Quit Bore`. The Settings window is the only window Bore opens, and only on request.

### Connected

```text
Bore

● Connected
nmoon-moose → 127.0.0.1:1080

Disconnect

────────────────

Quit Bore
```

### Disconnected

```text
Bore

○ Disconnected
nmoon-moose → 127.0.0.1:1080

Connect

────────────────

Quit Bore
```

### Connecting

```text
Bore

◌ Connecting…
nmoon-moose → 127.0.0.1:1080

────────────────

Quit Bore
```

### Failed

```text
Bore

⚠ Connection Failed
Address already in use

Retry

────────────────

Quit Bore
```

Avoid turning Bore into a dashboard.

---

# Connect / Disconnect Behavior

When disconnected, the primary action should be:

```text
Connect
```

When connected:

```text
Disconnect
```

While connecting:

```text
Connecting…
```

When failed:

```text
Retry
```

Retry should completely clean up the previous process state before attempting another connection.

The UI should respond immediately when the user requests a state change.

---

# Unexpected Disconnects

Bore must observe termination of its SSH process.

If SSH unexpectedly exits:

```text
Connected
    ↓
SSH terminates
    ↓
Failed / Disconnected
```

The menu bar state must update immediately.

Bore must distinguish between:

```text
User requested disconnect
```

and:

```text
Unexpected SSH termination
```

This distinction is required for automatic reconnect.

---

# Automatic Reconnection

Automatic reconnect should be implemented after the basic connection lifecycle is reliable.

If the SSH connection unexpectedly dies while the user still intends Bore to remain connected, Bore should attempt to restore the tunnel.

Use a stepped or exponential backoff.

Example:

```text
2 seconds
5 seconds
10 seconds
30 seconds
60 seconds
```

Cap the retry delay.

Conceptually:

```text
desiredState = connected
actualState = disconnected
```

means Bore should attempt reconnection.

However:

```text
desiredState = disconnected
actualState = disconnected
```

means Bore should remain disconnected.

Selecting **Disconnect** must always cancel pending reconnect attempts.

A successful connection should reset the reconnect backoff.

---

# Sleep / Wake

Test Bore when the Mac:

- Goes to sleep.
- Wakes from sleep.
- Changes Wi-Fi networks.
- Temporarily loses network connectivity.
- Regains network connectivity.
- Changes between Ethernet and Wi-Fi.
- Disconnects/reconnects from a VPN or Tailnet.

SSH may terminate during these transitions.

Bore should correctly detect this.

If automatic reconnect is enabled and:

```text
desiredState = connected
```

Bore should recover without requiring manual intervention.

---

# Settings

Settings are secondary to the MVP.

Eventually provide a small native Settings screen containing:

```text
SSH Host
[nmoon-moose]

SOCKS Port
[1080]

[ ] Connect automatically when Bore launches
[ ] Launch Bore at login
[ ] Automatically reconnect
```

The SOCKS bind address should remain:

```text
127.0.0.1
```

unless there is a deliberate future decision to make it configurable.

Persist simple settings using `UserDefaults`. Do not introduce a database.

Default behavior should remain usable without ever opening Settings.

## Implementation

Open Settings from the menu (`Settings…`, or Cmd+, while the menu is open). The window is `Bore/Settings/SettingsView.swift`; the model is `Bore/Settings/AppSettings.swift`.

Values live in the `com.nmoon.Bore` defaults domain:

| Key               | Type   | Default       |
|-------------------|--------|---------------|
| `sshHost`         | string | `nmoon-moose` |
| `socksPort`       | int    | `1080`        |
| `autoReconnect`   | bool   | `true`        |
| `connectAtLaunch` | bool   | `false`       |

Launch-at-login is not stored in defaults; `SMAppService.mainApp.status` is the source of truth.

Behavior:

- Edits save immediately.
- **Host and port apply on the next connect.** A running tunnel keeps the configuration it was started with (`TunnelManager.configuration` is a per-attempt snapshot). While connected with different settings, the menu shows `Settings changed; reconnect to apply`. An automatic reconnect counts as a connect and picks up the new values.
- **Auto-reconnect applies immediately.** Turning it off while a retry is pending cancels the retry and leaves the failure visible with a `Retry` action.
- Invalid settings (empty host, host starting with `-`, whitespace in host, port outside 1–65535) disable `Connect` and show the reason in the menu.

Reset to defaults from a shell with `defaults delete com.nmoon.Bore` (while Bore is quit).

---

# Launch at Login

Support launching Bore when the user logs into macOS.

Use Apple's current ServiceManagement APIs (`SMAppService.mainApp`). Because the login item points at the bundle on disk, if you move or rebuild `dist/Bore.app` elsewhere, toggle the setting off and on again. If macOS requires approval, the Settings window says so and the item appears under System Settings › General › Login Items.

Do not install custom launch daemons or manually manage LaunchAgent plist files unless technically required.

Launching Bore and connecting the tunnel should remain separate concepts.

For example:

```text
Launch Bore at login: YES
Connect automatically: NO
```

should result in Bore appearing in the menu bar in the disconnected state.

Whereas:

```text
Launch Bore at login: YES
Connect automatically: YES
```

should result in Bore appearing and establishing the tunnel automatically.

---

# Logging

Use lightweight native logging through `OSLog`.

Useful events include:

```text
Bore launched
Tunnel connection requested
SSH process launched
SOCKS listener detected
Tunnel connected
SSH process exited
Unexpected disconnect detected
Reconnect scheduled
Reconnect attempted
Tunnel disconnected by user
Tunnel terminated during Bore shutdown
```

Never log:

- Passwords
- Private key contents
- Authentication tokens
- Sensitive SSH environment information

Logging should primarily exist to make debugging connection lifecycle issues easy.

## Log file

In addition to `OSLog`, every lifecycle event and every line of `ssh` stderr is appended to a plain-text file:

```text
~/Library/Logs/Bore/Bore.log
```

Format: `<timestamp> [<category>] <level> <message>`, e.g.

```text
2026-10-02 11:05:32.772 [app] NOTICE Bore 0.1.0 (1) launched; log file: ...
2026-10-02 11:05:40.101 [tunnel] NOTICE SSH process launched (pid 1234): /usr/bin/ssh -D 127.0.0.1:1080 -N ...
2026-10-02 11:05:41.390 [ssh] stderr kex_exchange_identification: read: Connection reset by peer
2026-10-02 11:05:41.402 [tunnel] ERROR Tunnel failed: Connection reset by peer.
```

The file rotates once at 2 MB (`Bore.log` → `Bore.log.1`). "Open Logs" in the menu opens it in Console.app. Implementation lives in `Bore/BoreLog.swift` (`FileLog` + `BoreLogger`).

---

# Security

Bore must:

- Bind the SOCKS listener to `127.0.0.1`.
- Never store SSH private keys.
- Never request SSH passwords directly.
- Never log credentials.
- Never expose the SOCKS listener externally by default.
- Use the system OpenSSH client.
- Respect existing SSH configuration.
- Respect `known_hosts`.
- Preserve normal SSH host verification.

Do **not** automatically add options such as:

```text
StrictHostKeyChecking=no
```

Bore should not weaken the user's existing SSH security model.

---

# MVP

The first milestone is complete when Bore can reliably:

1. Run as a menu-bar-only macOS application.
2. Show connected/disconnected state.
3. Start the SSH SOCKS tunnel.
4. Verify `127.0.0.1:1080` becomes available.
5. Stop the SSH tunnel.
6. Detect unexpected SSH termination.
7. Capture and display useful SSH errors.
8. Clean up the SSH process when Bore exits.
9. Avoid interfering with unrelated SSH sessions.

Do not implement additional features until this lifecycle is reliable.

---

# Phase 2

After the MVP is stable:

1. ~~Add automatic reconnect.~~ Done.
2. Handle sleep/wake gracefully. (Not yet; relies on `ServerAlive*` keepalives to notice a dead tunnel after wake.)
3. ~~Add launch-at-login.~~ Done.
4. ~~Add connect-at-launch.~~ Done.
5. ~~Add configurable SSH host.~~ Done.
6. ~~Add configurable SOCKS port.~~ Done.
7. Improve diagnostic/error presentation. (File log + Open Logs done; in-menu detail could be richer.)

---

# Out of Scope

Do not implement the following in the initial project:

- Multiple simultaneous tunnels.
- SSH key management.
- SSH key generation.
- Password storage.
- Built-in SSH authentication.
- SSH terminal sessions.
- SFTP.
- Arbitrary port-forwarding configuration.
- HTTP proxy implementation.
- VPN functionality.
- Network Extension.
- Automatic macOS system proxy configuration.
- Generic SSH profile management.
- Cloud synchronization.
- Bore user accounts.

Bore is a convenient native controller around an existing OpenSSH SOCKS tunnel.

---

# Development Philosophy

Bore should remain small.

Prefer:

```text
Native macOS APIs
Simple Swift
Explicit state
Reliable process management
Minimal UI
```

over:

```text
Frameworks
Complex abstractions
Generic infrastructure
Premature extensibility
```

Do not design Bore around hypothetical future requirements.

The primary question for any new feature should be:

> Does this make turning the SSH tunnel on and off more reliable or convenient?

If not, it probably does not belong in Bore.

---

# Definition of Done

The intended core user experience is:

```text
Launch Bore
     ↓
Menu bar icon appears
     ↓
Click Bore
     ↓
Click Connect
     ↓
SSH starts
     ↓
SOCKS listener becomes available
     ↓
Bore shows Connected
     ↓
Use 127.0.0.1:1080
     ↓
Click Bore
     ↓
Click Disconnect
     ↓
SSH terminates
     ↓
Bore shows Disconnected
```

Once configured, Bore should require essentially no thought from the user.

Open the tunnel when needed.

Close the tunnel when finished.

That's it.

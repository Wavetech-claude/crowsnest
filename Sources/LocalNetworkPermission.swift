import Foundation
import Network

/// Triggers macOS's Local Network permission prompt for this app.
///
/// The prompt is otherwise deadlocked: macOS only offers it when the process
/// performing the local-network operation is long-lived, and the `ssh`
/// child this app spawns is refused and exits in milliseconds -- far too
/// short to be considered. Opening a plain TCP connection from the app
/// process itself, and holding it open for several seconds, gives macOS the
/// window it needs to show the dialog. Once granted, the app (and every
/// `ssh` child it spawns) is covered by the same per-app grant.
///
/// This does no SSH and reads no session data -- it only asks the question
/// macOS needs asked, once per launch. Outcomes are diagnosable via
/// `~/.crowsnest/local-network.log`; the main session list never shows
/// connection state, per the project's standing UI rule.
@MainActor
final class LocalNetworkPermission {
    enum Outcome: String {
        case ready    // connection succeeded -- permission already granted
        case waiting  // still pending -- typical while the prompt is up, or unanswered
        case failed   // the connection attempt itself failed (e.g. bad hostname)
    }

    private var connection: NWConnection?
    private var lastState: NWConnection.State?
    private let queue = DispatchQueue(label: "crowsnest.local-network-permission")

    /// Opens a TCP connection to `host:port` and holds it open for several
    /// seconds -- long enough for macOS to offer the Local Network prompt --
    /// before cancelling it cleanly. Call once per app launch, before the
    /// first poll. A no-op if `host` is empty.
    func prime(host: String, port: UInt16 = 22) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let target = resolvableTarget(for: trimmed)

        let conn = NWConnection(host: .init(target), port: nwPort, using: .tcp)
        connection = conn
        lastState = .setup

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.lastState = state
            }
        }
        conn.start(queue: queue)

        // The hold is the entire point -- a fire-and-forget attempt is
        // exactly what fails to trigger the prompt at all (that's what the
        // spawned `ssh` children already do). 7s gives macOS, and a human if
        // the dialog appears, time to act before we tear the probe down.
        //
        // The prompt-eligible state is `.preparing` (macOS deciding whether
        // to ask), which never resolves to `.ready`/`.failed`/`.waiting`
        // until the decision is made -- so the outcome that matters is
        // whatever state we're in the instant we tear down, not just the
        // states we happen to transition through first. Logging only on
        // transitions left the log empty for exactly this case.
        queue.asyncAfter(deadline: .now() + 7) { [weak self] in
            Task { @MainActor in
                self?.finish(host: target, port: port)
            }
        }
    }

    /// `store.host` is an `~/.ssh/config` alias (e.g. "winbox") -- it resolves
    /// fine for `ssh`, which reads that file, but the system resolver
    /// `NWConnection` uses does not consult it: a bare, dot-free hostname
    /// sits in `.waiting(NoSuchRecord)` forever and never reaches an actual
    /// LAN device, so it can never exercise (or trigger the prompt for)
    /// Local Network access at all. Bonjour/mDNS resolves the same short
    /// name under the standard `.local` suffix, so that's what gets probed;
    /// anything already containing a dot (an FQDN or a literal IP) is left
    /// alone. This does not change what `ssh` connects to -- only what this
    /// probe connects to.
    private func resolvableTarget(for host: String) -> String {
        host.contains(".") ? host : "\(host).local"
    }

    private func finish(host: String, port: UInt16) {
        record(lastState ?? .setup, host: host, port: port)

        guard let conn = connection else { return }
        connection = nil
        lastState = nil
        conn.cancel()
    }

    private func record(_ state: NWConnection.State, host: String, port: UInt16) {
        let outcome: Outcome
        var detail: String?
        switch state {
        case .ready:
            outcome = .ready
        case .failed(let error):
            outcome = .failed
            detail = error.localizedDescription
        case .waiting(let error):
            outcome = .waiting
            detail = error.localizedDescription
        case .setup, .preparing:
            // Never left the pre-connect stage in the hold window -- this is
            // the prompt-eligible state, not a failure to report as one.
            outcome = .waiting
            detail = "still preparing after the hold window"
        case .cancelled:
            outcome = .waiting
            detail = "cancelled before resolving"
        @unknown default:
            outcome = .waiting
            detail = "unrecognised state"
        }

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".crowsnest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = """
        primed: \(ISO8601DateFormatter().string(from: Date()))
        target: \(host):\(port)
        outcome: \(outcome.rawValue)
        detail: \(detail ?? "none")

        """
        try? line.write(to: dir.appendingPathComponent("local-network.log"),
                        atomically: true, encoding: .utf8)
    }
}

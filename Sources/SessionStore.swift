import Foundation
import SwiftUI

/// Polls the collector and publishes repo groups.
///
/// Transport failures are intentionally invisible to the UI. If the machine
/// can't be reached the session list is simply empty -- the app never shows
/// connection state, host names, or error rows. Failures land in `lastError`,
/// which only Settings reads.
@MainActor
final class SessionStore: ObservableObject {
    /// The one store the app polls and renders.
    ///
    /// Shared rather than owned by either side, because both need it and for
    /// different reasons: the app delegate starts polling at launch (so it
    /// does not depend on a panel ever being drawn), while the scene needs
    /// SwiftUI to own it properly or `MenuBarExtra`'s content closure does
    /// not observe it. Reaching through the delegate satisfied only the
    /// first, and the panel came up empty.
    static let shared = SessionStore()
    @Published private(set) var groups: [RepoGroup] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var collected: Int = 0
    @Published private(set) var hidden: [HiddenSession] = []

    @AppStorage("host") var host: String = "winbox" { didSet { refreshSoon() } }
    @AppStorage("includeThisMac") var includeThisMac: Bool = true { didSet { refreshSoon() } }
    @AppStorage("intervalSeconds") var intervalSeconds: Int = 15 { didSet { restartTimer() } }

    private var timer: Timer?
    private var task: Task<Void, Never>?

    var attentionCount: Int {
        groups.flatMap(\.sessions).filter(\.state.wantsAttention).count
    }

    var worst: Session.State {
        groups.flatMap(\.sessions).map(\.state).min(by: { $0.rank < $1.rank }) ?? .unknown
    }

    private var started = false
    private var taskStartedAt: Date?
    private var generation = 0
    private let notifier = Notifier()

    init() {}

    /// Preloaded, no polling. Used by the offline preview renderer.
    init(preloaded groups: [RepoGroup]) {
        self.groups = groups
        self.lastUpdate = Date()
    }

    /// Begins polling. Called from applicationDidFinishLaunching so that
    /// lifecycle depends on the app running, not on a panel being drawn.
    func start() {
        guard !started else { return }
        started = true
        notifier.requestAuthorization()
        restartTimer()
        refreshSoon()
    }

    private func restartTimer() {
        timer?.invalidate()
        guard started else { return }
        let every = Double(max(5, intervalSeconds))
        // .common, not the implicit .default: a timer in default mode does not
        // fire while a menu or panel is being tracked.
        let scheduled = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSoon() }
        }
        RunLoop.main.add(scheduled, forMode: .common)
        timer = scheduled
    }

    func refreshSoon() {
        if task != nil {
            // A hung poll must not wedge every future refresh. Abandon it once
            // it has overrun its budget and let the next one through.
            let budget = max(30, Double(intervalSeconds) * 2)
            guard let began = taskStartedAt,
                  Date().timeIntervalSince(began) > budget else { return }
            task?.cancel()
            task = nil
        }

        isRefreshing = true
        taskStartedAt = Date()
        generation &+= 1
        let mine = generation
        let host = self.host
        let includeLocal = self.includeThisMac

        task = Task { [weak self] in
            let result = await Collector.gather(host: host, includeLocal: includeLocal)
            await MainActor.run {
                guard let self, mine == self.generation else { return }
                self.groups = result.groups
                self.notifier.observe(result.groups.flatMap(\.sessions))
                self.lastError = result.error
                self.collected = result.collected
                self.hidden = result.hidden
                self.lastUpdate = Date()
                self.isRefreshing = false
                self.task = nil
                self.taskStartedAt = nil
                // Under the same generation guard as everything else published
                // here -- otherwise an abandoned poll that finishes late can
                // overwrite the log with stale data after a fresher poll
                // already landed.
                let sessionCount = result.groups.reduce(0) { $0 + $1.sessions.count }
                Collector.record(result.error, sessionCount: sessionCount)
            }
        }
    }
}

enum Collector {
    struct Result: Sendable {
        var groups: [RepoGroup]
        var error: String?
        var collected: Int = 0
        var hidden: [HiddenSession] = []
    }

    struct RunError: Error {
        var message: String
    }

    /// Path to collector.py. Resolved from the bundle so the app stays
    /// self-contained, with a source-tree fallback for development that is
    /// derived rather than hardcoded to one machine.
    static var scriptURL: URL? {
        if let bundled = Bundle.main.url(forResource: "collector", withExtension: "py") {
            return bundled
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()     // Sources/
            .deletingLastPathComponent()     // repo root
            .appendingPathComponent("collector.py")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    static func gather(host: String, includeLocal: Bool) async -> Result {
        // A fixture short-circuits the transport entirely, so the UI can be
        // built and verified when the machine is off-network.
        if let fixture = ProcessInfo.processInfo.environment["CLAUDE_FLEET_FIXTURE"],
           let data = FileManager.default.contents(atPath: fixture) {
            let payload = decode(data)
            let sessions = payload?.sessions ?? []
            return Result(groups: group(sessions),
                          error: nil,
                          collected: payload?.collected ?? sessions.count,
                          hidden: payload?.hidden ?? [])
        }

        var sessions: [Session] = []
        var problems: [String] = []
        var hidden: [HiddenSession] = []
        var collected = 0

        if includeLocal {
            let out = await run("/usr/bin/env", ["python3", scriptURL?.path ?? ""], stdin: URL?.none)
            switch out {
            case .success(let data):
                if let payload = decode(data) {
                    sessions += payload.sessions
                    hidden += payload.hidden ?? []
                    collected += payload.collected ?? payload.sessions.count
                    // The payload decoded fine but collector.py itself raised
                    // while collecting (main()'s except branch) -- a
                    // successful decode of an empty session list, with no
                    // explanation, is exactly the silent failure this exists
                    // to surface.
                    if payload.ok == false, let error = payload.error {
                        problems.append("this Mac: \(error)")
                    }
                } else {
                    problems.append("this Mac: unreadable collector output")
                }
            case .failure(let why): problems.append("this Mac: \(why.message)")
            }
        }

        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let script = scriptURL {
            var failure: String?
            for interpreter in interpreters(for: trimmed) {
                let args = [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=6",
                    // Deliberately NOT StrictHostKeyChecking=accept-new. That
                    // would silently trust an unknown host on first sight, so
                    // anyone on the same network could answer for the remote
                    // and thereafter author every string this app renders and
                    // copies. Leaving it unset lets the owner's own ~/.ssh
                    // config govern; with BatchMode an unknown host then fails
                    // closed, and the error surfaces in Settings -> Diagnostics
                    // ("run `ssh <host>` once to trust it").
                    // ConnectTimeout only bounds the handshake -- a connection
                    // that stalls afterwards (dead Wi-Fi, sleeping remote) is
                    // otherwise held open by the user's own ~/.ssh/config,
                    // which can set ServerAliveInterval/CountMax to tens of
                    // minutes before ssh gives up. These override that,
                    // bounding a post-connect stall to ~10s so an abandoned
                    // poll's `ssh` child dies promptly instead of outliving
                    // the app's patience by 180x.
                    "-o", "ServerAliveInterval=5",
                    "-o", "ServerAliveCountMax=2",
                    // One handshake shared across polls rather than one per poll.
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=\(controlPath)",
                    "-o", "ControlPersist=300",
                    // `--` so a host value beginning with `-` is treated as a
                    // destination, never as an ssh option (e.g. a crafted
                    // -oProxyCommand). Harmless for normal aliases.
                    "--", trimmed, "\(interpreter) - \(trimmed)",
                ]
                switch await run("/usr/bin/ssh", args, stdin: script) {
                case .success(let data):
                    if let payload = decode(data) {
                        // A decoded payload means this was the right
                        // interpreter, whether or not collector.py itself
                        // succeeded -- so remember it and stop trying others.
                        // Misreading an `ok:false` payload as "wrong
                        // interpreter" would retry a genuine error away.
                        rememberInterpreter(interpreter, for: trimmed)
                        sessions += payload.sessions
                        hidden += payload.hidden ?? []
                        collected += payload.collected ?? payload.sessions.count
                        if payload.ok == false, let error = payload.error {
                            failure = "\(trimmed): \(error)"
                        } else {
                            failure = nil
                        }
                    } else {
                        failure = "\(trimmed): \(interpreter) produced no usable output"
                        continue    // wrong interpreter for this machine -- try the next
                    }
                case .failure(let why):
                    failure = "\(trimmed): \(why.message)"
                    continue
                }
                break
            }
            if let failure { problems.append(failure) }
        } else if !trimmed.isEmpty {
            // scriptURL is nil -- collector.py is missing from the bundle
            // (a build regression). Without this, a configured host is
            // silently skipped: a calm empty list with `error: none`.
            problems.append("\(trimmed): collector.py is missing from the app bundle")
        }

        let error = problems.isEmpty ? nil : problems.joined(separator: "\n")
        return Result(groups: group(sessions),
                      error: error,
                      collected: collected,
                      hidden: hidden)
    }

    /// Last-poll diagnostics, written where they can be read after the fact.
    ///
    /// A menu bar app has nowhere to show transport failures -- by design, the
    /// session list never displays them -- so without this a failure is
    /// invisible unless someone happens to open Settings at the right moment.
    /// One file, overwritten each poll, no history to grow unbounded.
    fileprivate static func record(_ error: String?, sessionCount: Int) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-fleet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = """
        polled: \(ISO8601DateFormatter().string(from: Date()))
        sessions: \(sessionCount)
        error: \(error ?? "none")

        """
        try? line.write(to: dir.appendingPathComponent("last-poll.log"),
                        atomically: true, encoding: .utf8)
    }

    /// Which command runs Python on a given machine. Windows is the awkward
    /// case: `python`/`python3` there are Microsoft Store stub aliases that
    /// print an install prompt and exit, so only `py` actually works. The
    /// winner is cached per host, with the full list retried behind it in case
    /// the machine changes.
    private static func interpreters(for host: String) -> [String] {
        let all = ["python3", "py", "python"]
        guard let cached = UserDefaults.standard.string(forKey: "interpreter.\(host)"),
              all.contains(cached)
        else { return all }
        return [cached] + all.filter { $0 != cached }
    }

    private static func rememberInterpreter(_ interpreter: String, for host: String) {
        UserDefaults.standard.set(interpreter, forKey: "interpreter.\(host)")
    }

    private static var controlPath: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-fleet/cm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("%r@%h:%p").path
    }

    /// Bridges `Task` cancellation to the `Process` a `run()` call spawns.
    ///
    /// `withCheckedContinuation` has no cancellation support of its own --
    /// `Task.cancel()` on the awaiting task marks it cancelled and nothing
    /// more. Without this, an abandoned poll's `ssh` child (and the thread
    /// blocked in its `readDataToEndOfFile()` calls) runs forever. Guarded by
    /// a lock because `launched(_:)` (the background queue, once `proc.run()`
    /// succeeds) and `cancel()` (the cancellation handler, which may fire on
    /// any thread before, during, or after `launched`) race: `Process.
    /// terminate()` on a process that has not yet launched throws, so a
    /// cancel that arrives first must be remembered and applied the instant
    /// the process exists rather than acted on immediately.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var proc: Process?
        private var cancelled = false

        func launched(_ p: Process) {
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                p.terminate()
            } else {
                proc = p
            }
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            proc?.terminate()
        }
    }

    private static func run(_ launch: String, _ args: [String], stdin: URL?) async -> Swift.Result<Data, RunError> {
        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: launch)
                    proc.arguments = args
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    proc.standardOutput = outPipe
                    proc.standardError = errPipe
                    if let stdin, let handle = try? FileHandle(forReadingFrom: stdin) {
                        proc.standardInput = handle
                    }
                    do {
                        try proc.run()
                    } catch {
                        continuation.resume(returning: .failure(RunError(message: error.localizedDescription)))
                        return
                    }
                    // Registers the live process so `onCancel` below has
                    // something to terminate. `waitUntilExit`/
                    // `readDataToEndOfFile` still run to completion on this
                    // thread and still resume the continuation exactly once
                    // -- terminate() only makes them unblock promptly instead
                    // of never.
                    box.launched(proc)

                    // stderr must be drained concurrently. An unread pipe fills at
                    // ~64KB and blocks the child forever; ssh -v alone can exceed
                    // that. Draining it also gives failures a real message instead
                    // of a bare exit code, which is the difference between a
                    // diagnosable problem and a silently empty list.
                    var errData = Data()
                    let errQueue = DispatchQueue(label: "claude-fleet.stderr")
                    let errDone = DispatchSemaphore(value: 0)
                    errQueue.async {
                        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        errDone.signal()
                    }

                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    errDone.wait()

                    if proc.terminationStatus != 0 && data.isEmpty {
                        let detail = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let message = detail.isEmpty
                            ? "exit \(proc.terminationStatus)"
                            : "exit \(proc.terminationStatus): \(detail.suffix(400))"
                        continuation.resume(returning: .failure(RunError(message: message)))
                    } else {
                        continuation.resume(returning: .success(data))
                    }
                }
            }
        } onCancel: {
            // May run before `proc.run()` has even happened -- `cancel()`
            // handles that by latching the flag for `launched(_:)` to act on.
            box.cancel()
        }
    }

    /// The collector brackets its JSON so a login banner on the remote shell
    /// can't corrupt the parse. `nil` means "not usable output" -- either the
    /// markers were missing (wrong interpreter) or the JSON inside them
    /// didn't decode.
    private static func decode(_ data: Data) -> CollectorPayload? {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: "<<<CLAUDE_FLEET>>>"),
              let end = text.range(of: "<<<END>>>", range: start.upperBound..<text.endIndex)
        else { return nil }

        let json = String(text[start.upperBound..<end.lowerBound])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(CollectorPayload.self, from: Data(json.utf8))
    }

    /// The collector now owns all filtering -- it drops dead sessions itself
    /// and reports them in `hidden` -- so grouping trusts everything it's
    /// handed. Filtering again here is what previously let a session vanish
    /// with no explanation.
    private static func group(_ sessions: [Session]) -> [RepoGroup] {
        var buckets: [String: [Session]] = [:]
        for session in sessions {
            buckets[session.repoRoot ?? session.cwd ?? "?", default: []].append(session)
        }
        return buckets.map { path, items in
            let sorted = items.sorted {
                $0.state.rank != $1.state.rank
                    ? $0.state.rank < $1.state.rank
                    : ($0.ageSecs ?? .infinity) < ($1.ageSecs ?? .infinity)
            }
            return RepoGroup(
                id: path,
                name: sorted.first?.repoName ?? (path as NSString).lastPathComponent,
                path: path,
                sessions: sorted
            )
        }
        // Repos with something waiting on you float to the top.
        .sorted {
            $0.worst.rank != $1.worst.rank ? $0.worst.rank < $1.worst.rank : $0.name < $1.name
        }
    }
}

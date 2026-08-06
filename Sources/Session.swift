import SwiftUI

/// Shell quoting for strings that reach a terminal via the clipboard.
///
/// Every path and id the app can copy originates on the remote machine, so a
/// compromised or shared host could otherwise smuggle shell metacharacters
/// into a command the owner pastes and runs on their own Mac. Lives here,
/// beside the decode-time sanitisation, so all handling of untrusted remote
/// strings sits in one file -- and so it is reachable by the offline tests.
enum Shell {
    /// Single-quote wrap, escaping embedded single quotes the POSIX way
    /// (`'\''`), and strip control characters -- a newline in an unquoted
    /// value would otherwise let the rest of it run as its own command.
    static func quote(_ raw: String) -> String {
        let cleaned = raw.filter { !$0.isNewline && $0 != "\r" && $0 != "\0" }
        return "'" + cleaned.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// One Claude Code session, as reported by collector.py.
struct Session: Decodable, Identifiable, Sendable, Equatable {
    var sessionId: String
    var state: State
    var stateReason: String?
    var name: String?
    var cwd: String?
    var repoRoot: String?
    var repoName: String?
    var relPath: String?
    var model: String?
    var contextTokens: Int?
    var ageSecs: Double?
    var gitBranch: String?

    var id: String { sessionId }

    private enum CodingKeys: String, CodingKey {
        case sessionId, state, stateReason, name, cwd, repoRoot, repoName
        case relPath, model, contextTokens, ageSecs, gitBranch
    }

    /// The characters a legitimate session id can contain -- a UUID, or the
    /// slug the CLI derives from one. A CharacterSet check rather than a regex
    /// so there is no anchoring subtlety: a trailing newline (which ICU's `$`
    /// would tolerate) simply isn't in the set, so it's rejected like any
    /// other stray byte.
    private static let idAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let rawId = try c.decode(String.self, forKey: .sessionId)
        let ok = !rawId.isEmpty
            && rawId.count <= 128
            && !rawId.hasPrefix("-")   // so it can never be read as a flag to `claude`
            && rawId.unicodeScalars.allSatisfy { Session.idAllowed.contains($0) }
        guard ok else {
            // Reject the whole row rather than sanitise the id: a malformed id
            // is either corruption or an attack, and there is no safe repair
            // that keeps `--resume` correct.
            throw DecodingError.dataCorruptedError(
                forKey: .sessionId, in: c,
                debugDescription: "session id is not a plausible Claude Code id")
        }
        sessionId = rawId

        state = try c.decode(State.self, forKey: .state)
        // Every free-text field below originates on the remote machine and
        // ends up in a tooltip, a notification, or (via Copy Path) the
        // clipboard. Strip control characters on the way in so a crafted
        // value cannot smuggle a newline into any of those sinks. Shell
        // quoting at the clipboard is the real barrier; this is defence in
        // depth for the other sinks.
        stateReason = Session.clean(try c.decodeIfPresent(String.self, forKey: .stateReason))
        name        = Session.clean(try c.decodeIfPresent(String.self, forKey: .name))
        cwd         = Session.clean(try c.decodeIfPresent(String.self, forKey: .cwd))
        repoRoot    = Session.clean(try c.decodeIfPresent(String.self, forKey: .repoRoot))
        repoName    = Session.clean(try c.decodeIfPresent(String.self, forKey: .repoName))
        relPath     = Session.clean(try c.decodeIfPresent(String.self, forKey: .relPath))
        model       = Session.clean(try c.decodeIfPresent(String.self, forKey: .model))
        gitBranch   = Session.clean(try c.decodeIfPresent(String.self, forKey: .gitBranch))
        contextTokens = try c.decodeIfPresent(Int.self, forKey: .contextTokens)
        ageSecs       = try c.decodeIfPresent(Double.self, forKey: .ageSecs)
    }

    /// Strip anything that could act as a line break or control byte in a
    /// tooltip, notification, log line, or clipboard string. `.newlines`
    /// covers not just LF/CR but the Unicode line/paragraph separators
    /// (U+2028/U+2029) and NEL that a terminal or some UI still treats as a
    /// break. Shared with `CollectorPayload`/`HiddenSession` so every remote
    /// string is cleaned the same way.
    private static let stripped = CharacterSet.controlCharacters.union(.newlines)

    static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        return String(s.unicodeScalars.filter { !Session.stripped.contains($0) })
    }

    /// Memberwise init, restored because defining `init(from:)` suppresses the
    /// synthesised one. Used by tests and the preview fixtures to build a
    /// session directly; the live path always comes through `init(from:)`.
    init(sessionId: String, state: State, stateReason: String? = nil,
         name: String? = nil, cwd: String? = nil, repoRoot: String? = nil,
         repoName: String? = nil, relPath: String? = nil, model: String? = nil,
         contextTokens: Int? = nil, ageSecs: Double? = nil, gitBranch: String? = nil) {
        self.sessionId = sessionId
        self.state = state
        self.stateReason = stateReason
        self.name = name
        self.cwd = cwd
        self.repoRoot = repoRoot
        self.repoName = repoName
        self.relPath = relPath
        self.model = model
        self.contextTokens = contextTokens
        self.ageSecs = ageSecs
        self.gitBranch = gitBranch
    }

    enum State: String, Decodable, Sendable, CaseIterable {
        case blocked, waiting, working, idle, unknown

        /// Sort order: things that want a human first.
        var rank: Int {
            switch self {
            case .blocked: 0
            case .waiting: 1
            case .working: 2
            case .unknown: 3
            case .idle:    4
            }
        }

        var tint: Color {
            switch self {
            case .blocked: .orange
            case .waiting: .yellow
            case .working: .green
            case .idle, .unknown: .secondary
            }
        }

        var wantsAttention: Bool { self == .blocked || self == .waiting }

        var label: String {
            switch self {
            case .blocked: "Needs approval"
            case .waiting: "Your turn"
            case .working: "Working"
            case .idle:    "Idle"
            case .unknown: "Unknown"
            }
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .unknown
        }
    }

    /// What to call this session in a row: the derived name, else the
    /// subdirectory inside the repo, else the repo itself.
    var title: String {
        if let name, !name.isEmpty { return name }
        if let relPath, !relPath.isEmpty { return relPath }
        // Sitting at the repo root; the group header already names the repo.
        return "root"
    }

    var shortModel: String? {
        guard let model, !model.isEmpty else { return nil }
        return model.replacingOccurrences(of: "claude-", with: "")
    }

    /// Percent of the context window in use. The window isn't reported, so it
    /// is inferred: anything past 200k must be running on a 1M-context model.
    var contextPercent: Int? {
        guard let contextTokens, contextTokens > 0 else { return nil }
        let window = contextTokens > 200_000 ? 1_000_000.0 : 200_000.0
        return min(100, Int((Double(contextTokens) / window * 100).rounded()))
    }

    var contextLabel: String? {
        guard let contextTokens, contextTokens > 0 else { return nil }
        let thousands = contextTokens / 1000
        guard let percent = contextPercent else { return "\(thousands)k" }
        return "\(thousands)k · \(percent)%"
    }

    var age: String {
        guard let ageSecs else { return "" }
        let s = Int(ageSecs)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// A repo with the sessions running inside it. This is the only grouping the
/// UI has -- machines are deliberately not a dimension the user sees.
struct RepoGroup: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var path: String
    var sessions: [Session]

    var worst: Session.State {
        sessions.map(\.state).min(by: { $0.rank < $1.rank }) ?? .unknown
    }
}

struct HiddenSession: Decodable, Sendable, Equatable, Identifiable {
    var sessionId: String
    var reason: String

    var id: String { sessionId }

    private enum CodingKeys: String, CodingKey { case sessionId, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `reason` is remote-controlled and lands in ~/.crowsnest/last-poll.log
        // and Settings -> Diagnostics; clean it like every other remote string.
        sessionId = Session.clean(try c.decode(String.self, forKey: .sessionId)) ?? ""
        reason = Session.clean(try c.decode(String.self, forKey: .reason)) ?? ""
    }

    init(sessionId: String, reason: String) {
        self.sessionId = sessionId
        self.reason = reason
    }
}

struct CollectorPayload: Decodable, Sendable {
    var sessions: [Session]
    var hidden: [HiddenSession]?
    var collected: Int?
    var ok: Bool?
    var error: String?

    private enum CodingKeys: String, CodingKey {
        case sessions, hidden, collected, ok, error
    }

    /// `hidden`, `collected`, `ok`, and `error` are diagnostics about the
    /// session list, not the session list itself. A malformed entry in any
    /// of them must never be able to fail the whole decode and take
    /// `sessions` down with it -- that is exactly the silent-empty-list
    /// failure this app exists to eliminate. `sessions` is the only field
    /// allowed to fail the payload.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Strict on the key: a missing `sessions` field is a genuine collector
        // failure and must fail the payload. Lenient per element: one
        // malformed or rejected row (e.g. a session id that fails validation)
        // loses only itself rather than blanking the whole machine's list --
        // the same rule `hidden` follows, and the same silent-empty-list
        // failure this app exists to prevent.
        sessions = try container.decode([SessionOrInvalid].self, forKey: .sessions)
            .compactMap(\.value)

        // Lenient: absent or malformed as a whole -> []. A single bad
        // element -> decoded individually so it loses only itself.
        hidden = (try? container.decode([HiddenSessionOrInvalid].self, forKey: .hidden))?
            .compactMap(\.value) ?? []

        // Lenient: absent or malformed -> nil.
        collected = try? container.decode(Int.self, forKey: .collected)

        // Lenient: this is collector.py's own "I raised while collecting"
        // signal (main()'s except branch). A malformed `ok`/`error` must
        // never mask a real error, but must also never fail a payload that
        // otherwise decoded a perfectly good session list.
        //
        // `error` is cleaned like every other remote string: a compromised
        // remote controls these bytes, and they are written to
        // ~/.crowsnest/last-poll.log -- which the docs tell users to `cat`
        // when debugging. Stripping control characters keeps a crafted value
        // from planting terminal escape sequences that fire on `cat`.
        ok = try? container.decode(Bool.self, forKey: .ok)
        error = Session.clean(try? container.decode(String.self, forKey: .error))
    }
}

/// Decodes a single `hidden` array element without ever throwing, so that
/// decoding `[HiddenSessionOrInvalid]` always consumes exactly one element
/// per entry -- a plain `try?` inside a hand-rolled unkeyed-container loop
/// does not advance the container's index on failure and spins forever.
private struct HiddenSessionOrInvalid: Decodable {
    var value: HiddenSession?

    init(from decoder: Decoder) throws {
        value = try? HiddenSession(from: decoder)
    }
}

/// The same never-throwing wrapper for `sessions`, so a single row that fails
/// validation (an implausible session id) is dropped rather than failing the
/// entire array.
private struct SessionOrInvalid: Decodable {
    var value: Session?

    init(from decoder: Decoder) throws {
        value = try? Session(from: decoder)
    }
}

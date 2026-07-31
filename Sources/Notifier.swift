import Foundation
import UserNotifications

/// Fires once when a session *enters* a state that wants the owner.
///
/// Two rules, both from hard experience with notification spam:
///   - never re-notify while a session sits in the same state;
///   - never notify for a state that was already true at launch, or opening
///     the app with eight blocked sessions produces eight alerts at once.
@MainActor
final class Notifier {
    /// Last known state per session, retained across polls that did not
    /// mention it. Stickiness is what separates "we lost sight of this
    /// session for a poll" from "this session is new" -- see `observe`.
    private struct Tracked {
        var state: Session.State
        var missedPolls: Int
    }

    private var previous: [String: Tracked] = [:]
    private var seeded = false
    private var authorized: Bool
    /// The actual notification-posting side effect, injected so `observe`'s
    /// decision logic -- the part with real invariants and no executable
    /// statement of them -- can be exercised offline in `swift-tests/`
    /// without touching `UNUserNotificationCenter`.
    private let post: @MainActor (Session) -> Void

    init(authorized: Bool = false, post: @escaping @MainActor (Session) -> Void = Notifier.deliver) {
        self.authorized = authorized
        self.post = post
    }

    /// How many consecutive polls a session may be absent before it is
    /// forgotten. Long enough to outlast a transient remote-host outage,
    /// short enough that the map cannot grow without bound.
    ///
    /// Counted in polls, not seconds, so the wall-clock span scales with
    /// `intervalSeconds` — roughly 5 minutes at the 15s default, longer if
    /// the owner slows the refresh down.
    private let forgetAfterMissedPolls = 20

    /// How recently a never-before-seen session must have acted for its first
    /// sighting to count as news.
    ///
    /// A session with no history is genuinely ambiguous: it is either brand
    /// new, or it existed all along and we simply could not see it -- if the
    /// remote host was unreachable across the very first poll, `seeded` was
    /// spent on a poll that never contained it, so it enters the map only
    /// when the host returns. Those two cases are indistinguishable by
    /// identity alone, and treating every first sighting as news turns a
    /// reconnect into the launch burst this class exists to prevent.
    ///
    /// Age breaks the tie. A session that has been sitting blocked for hours
    /// did not just start needing you; one that went quiet ninety seconds ago
    /// did. `collector.py` only calls a session blocked once it has been
    /// still for 90s, so anything under this bound is as fresh as a blocked
    /// session can be.
    ///
    /// `waiting` has no such floor — a turn can end and be reported within
    /// seconds — so a first-ever sighting of a session that finished its turn
    /// more than five minutes ago stays quiet. That is deliberate: the
    /// dominant path into `waiting` is a tracked session transitioning out of
    /// `working`, which notifies on the state change regardless of age. Only
    /// the ambiguous never-seen-before case is held to this bound, and there
    /// under-notifying beats risking a burst.
    private let firstSightingGrace: TimeInterval = 300

    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in self?.authorized = granted }
            }
    }

    func observe(_ sessions: [Session]) {
        let current = Dictionary(sessions.map { ($0.sessionId, $0.state) },
                                 uniquingKeysWith: { first, _ in first })
        defer { retain(current) }

        // The first poll only establishes a baseline.
        guard seeded else { seeded = true; return }
        guard authorized else { return }

        for session in sessions where session.state.wantsAttention {
            if let prior = previous[session.sessionId]?.state {
                // Known session: report only a real change of state. Sitting
                // in the same state across polls -- including across an
                // outage, since `previous` is sticky -- stays quiet.
                guard prior != session.state else { continue }
            } else {
                // Never seen before, so it is either brand new or was merely
                // invisible until now. Only recent activity counts as news;
                // see `firstSightingGrace`.
                guard let age = session.ageSecs, age < firstSightingGrace else { continue }
            }
            post(session)
        }
    }

    /// Merge this poll into the history rather than replacing it.
    ///
    /// Replacing wholesale would drop every session absent from a partial
    /// poll, so the next successful poll would see them all as new and fire
    /// a burst. Entries are aged out once they have been missing long enough
    /// to be genuinely gone rather than temporarily unreachable.
    private func retain(_ current: [String: Session.State]) {
        for (id, state) in current {
            previous[id] = Tracked(state: state, missedPolls: 0)
        }
        for id in previous.keys where current[id] == nil {
            let missed = (previous[id]?.missedPolls ?? 0) + 1
            if missed > forgetAfterMissedPolls {
                previous.removeValue(forKey: id)
            } else {
                previous[id]?.missedPolls = missed
            }
        }
    }

    /// The real implementation of `post`, and the default `init` uses.
    static func deliver(_ session: Session) {
        let content = UNMutableNotificationContent()
        content.title = session.state.label
        content.body = [session.repoName, session.title]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        content.sound = session.state == .blocked ? .default : nil

        let request = UNNotificationRequest(
            identifier: "\(session.sessionId)-\(session.state.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

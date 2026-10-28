import SwiftUI
import AppKit

struct MenuPanel: View {
    @ObservedObject var store: SessionStore
    /// ScrollView doesn't lay out its content under ImageRenderer, so the
    /// offline preview renders the identical view tree without it.
    var scrolls: Bool = true
    @State private var showingSettings = false
    @State private var listHeight: CGFloat = 0
    /// The session whose resume command was just copied: its card reads
    /// "Copied" in place of its age for a moment.
    @State private var copiedId: String?
    @State private var clearCopied: DispatchWorkItem?

    /// Tallest the list may grow before it starts scrolling.
    private let maxListHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if store.groups.isEmpty {
                emptyState
            } else if scrolls {
                // A ScrollView has no height of its own: it takes whatever it
                // is offered. A MenuBarExtra window sizes itself to its
                // content, so it offers nothing, the ScrollView resolves to
                // zero, and the panel renders as a header and footer with an
                // empty gap between them. Measuring the content and asking
                // for that height (capped) gives the window something
                // concrete to size to.
                ScrollView {
                    sessionList
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: ListHeightKey.self,
                                                       value: proxy.size.height)
                            }
                        )
                }
                .frame(height: min(max(listHeight, 1), maxListHeight))
                .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            } else {
                sessionList
            }

            Divider()
            footer
        }
        .frame(width: 360)
        .sheet(isPresented: $showingSettings) {
            SettingsPanel(store: store, isPresented: $showingSettings)
        }
    }

    /// Every session, most urgent first. What needs you is a full-width card;
    /// everything else is a tile, two to a row. The repository is named on each
    /// card instead of as a group header, so urgency, not repository, decides
    /// the order.
    private var sessionList: some View {
        let items = SessionItem.ranked(store.groups)
        let hot = items.filter { $0.session.state.wantsAttention }
        let calm = items.filter { !$0.session.state.wantsAttention }
        let rows = stride(from: 0, to: calm.count, by: 2).map { Array(calm[$0..<min($0 + 2, calm.count)]) }

        return VStack(spacing: 8) {
            ForEach(hot) { item in
                AttentionCard(item: item, copied: copiedId == item.id) { copyResume(item) }
            }
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(rows[r]) { item in
                        SessionTile(item: item, copied: copiedId == item.id) { copyResume(item) }
                    }
                    if rows[r].count == 1 { Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claude Sessions")
                .font(.system(.headline, design: .rounded))
            Spacer()
            Group {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Button {
                        store.refreshSoon()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.panelSecondary)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.panelText.opacity(0.06)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
                }
            }
            .frame(width: 26, height: 26)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.panelSecondary)
            Text("No active sessions")
                .font(.callout)
                .foregroundStyle(Color.panelSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            FooterButton(title: "Settings…", symbol: "gearshape") { showingSettings = true }
            Spacer()
            FooterButton(title: "Quit", symbol: nil) { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func copyResume(_ item: SessionItem) {
        Pasteboard.copy(item.resumeCommand)
        copiedId = item.id
        clearCopied?.cancel()
        let reset = DispatchWorkItem { copiedId = nil }
        clearCopied = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: reset)
    }
}

/// A session together with the repository it was found in.
struct SessionItem: Identifiable {
    let session: Session
    let repoName: String
    let repoPath: String

    var id: String { session.id }

    /// Most urgent first; sessions of the same state keep the collector's order.
    static func ranked(_ groups: [RepoGroup]) -> [SessionItem] {
        groups.flatMap { g in g.sessions.map { SessionItem(session: $0, repoName: g.name, repoPath: g.path) } }
            .enumerated()
            .sorted { ($0.element.session.state.rank, $0.offset) < ($1.element.session.state.rank, $1.offset) }
            .map(\.element)
    }

    /// "repo · branch", the branch left out when there isn't a real one.
    var place: String {
        guard let branch = session.gitBranch, !branch.isEmpty, branch != "HEAD" else { return repoName }
        return "\(repoName) · \(branch)"
    }

    /// A command the owner pastes into a terminal. Every interpolated value --
    /// the working directory and the session id -- originates on the remote
    /// machine, so a compromised or shared host could otherwise smuggle shell
    /// metacharacters straight into a command the owner runs on their own Mac.
    /// Both are shell-quoted; `sessionId` is additionally validated at decode.
    var resumeCommand: String {
        "cd \(Shell.quote(session.cwd ?? repoPath)) && claude --resume \(Shell.quote(session.sessionId))"
    }

    var quotedPath: String { Shell.quote(session.cwd ?? repoPath) }

    var spokenLabel: String {
        "\(session.title), \(session.state.label), \(place), \(session.age) ago"
    }
}

private enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A session that needs you: a full-width card in its state's tint.
private struct AttentionCard: View {
    let item: SessionItem
    let copied: Bool
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        let s = item.session
        let tint = Color.stateTint(s.state)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        Button(action: onCopy) {
            HStack(alignment: .top, spacing: 12) {
                StateDisc(state: s.state, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(s.state.label)
                            .font(.system(.caption, design: .rounded).weight(.heavy))
                            .foregroundStyle(Color.panelText)
                        Spacer(minLength: 4)
                        AgeOrCopied(age: s.age, copied: copied)
                    }
                    Text(s.title)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.panelText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.place)
                        .font(.caption)
                        .foregroundStyle(Color.panelSecondary)
                        .lineLimit(1)
                    if let percent = s.contextPercent {
                        ContextBar(percent: percent).padding(.top, 3)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(LinearGradient(colors: [tint.opacity(Palette.cardTintStrong),
                                                           tint.opacity(Palette.cardTintWeak)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(Color.panelText.opacity(hovering ? 0.2 : 0), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(s.stateReason ?? s.state.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spokenLabel)
        .accessibilityHint("Copies the resume command")
        .accessibilityAddTraits(.isButton)
        .contextMenu { RowActions(item: item) }
    }
}

/// A session that doesn't need you: a small tile, two to a row.
private struct SessionTile: View {
    let item: SessionItem
    let copied: Bool
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        let s = item.session
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Button(action: onCopy) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    StateDisc(state: s.state, size: 22)
                    Spacer(minLength: 4)
                    AgeOrCopied(age: s.age, copied: copied)
                }
                Text(s.title)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.panelText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(s.state.label) · \(item.repoName)")
                    .font(.caption)
                    .foregroundStyle(Color.panelSecondary)
                    .lineLimit(1)
                if let percent = s.contextPercent {
                    ContextBar(percent: percent)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.panelText.opacity(hovering ? Palette.tileFill * 2 : Palette.tileFill)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        .help(s.stateReason ?? s.state.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spokenLabel)
        .accessibilityHint("Copies the resume command")
        .accessibilityAddTraits(.isButton)
        .contextMenu { RowActions(item: item) }
    }
}

private struct RowActions: View {
    let item: SessionItem
    var body: some View {
        Button("Copy Resume Command") { Pasteboard.copy(item.resumeCommand) }
        Button("Copy Path") { Pasteboard.copy(item.quotedPath) }
    }
}

/// The state as a shape as well as a colour: a filled disc with the state's
/// glyph, so the state reads without the tint.
private struct StateDisc: View {
    let state: Session.State
    let size: CGFloat

    private var symbol: String {
        switch state {
        case .blocked: "hand.raised.fill"
        case .waiting: "text.bubble.fill"
        case .working: "bolt.fill"
        case .idle:    "moon.fill"
        case .unknown: "questionmark"
        }
    }

    var body: some View {
        let bright = Palette.isBright(state)
        ZStack {
            if bright {
                Circle().fill(Color.stateTint(state).gradient)
            } else {
                Circle().fill(Color.panelText.opacity(Palette.quietDiscFill))
            }
            Image(systemName: symbol)
                .font(.system(size: size * 0.43, weight: .bold))
                .foregroundStyle(bright ? Color(nsColor: Palette.glyphOnTint) : Color.panelSecondary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// How full the session's context window is: a bar plus the number. Red at
/// `Palette.contextWarnPercent` and above, when a fresh start is near.
private struct ContextBar: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.panelText.opacity(0.09))
                    Capsule()
                        .fill(percent >= Palette.contextWarnPercent ? Color(nsColor: .systemRed)
                                                                     : Color.panelText.opacity(0.4))
                        .frame(width: geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
                }
            }
            .frame(height: 4)
            Text("\(percent)%")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.panelSecondary)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(percent) percent full")
    }
}

private struct AgeOrCopied: View {
    let age: String
    let copied: Bool

    var body: some View {
        if copied {
            Label("Copied", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.panelSecondary)
        } else {
            Text(age)
                .font(.caption)
                .foregroundStyle(Color.panelSecondary)
                .monospacedDigit()
        }
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Label(title, systemImage: symbol)
                } else {
                    Text(title)
                }
            }
            .font(.callout)
            .foregroundStyle(Color.panelSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? Color.panelText.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SettingsPanel: View {
    @ObservedObject var store: SessionStore
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            Form {
                TextField("Machine", text: $store.host)
                    .textFieldStyle(.roundedBorder)
                    .help("An alias from ~/.ssh/config — the same one VS Code Remote-SSH uses")

                Toggle("Include this Mac", isOn: $store.includeThisMac)

                Picker("Refresh every", selection: $store.intervalSeconds) {
                    Text("5 seconds").tag(5)
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                }
            }
            .formStyle(.grouped)

            // Diagnostics live here and nowhere else. The session list never
            // shows transport state, counts, or errors.
            VStack(alignment: .leading, spacing: 3) {
                Text("Diagnostics")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.panelSecondary)

                Text("\(store.collected) collected · \(store.hidden.count) hidden")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.panelSecondary)

                ForEach(store.hidden) { item in
                    Text("• \(item.reason)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.panelSecondary)
                        .lineLimit(1)
                }

                if let error = store.lastError {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.panelSecondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 330)
    }
}

/// Carries the measured height of the session list up to `MenuPanel`, so the
/// enclosing ScrollView can be given a concrete height instead of collapsing
/// to zero inside a self-sizing menu bar window.
private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

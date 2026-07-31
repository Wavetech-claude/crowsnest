import SwiftUI
import AppKit

struct MenuPanel: View {
    @ObservedObject var store: SessionStore
    /// ScrollView doesn't lay out its content under ImageRenderer, so the
    /// offline preview renders the identical view tree without it.
    var scrolls: Bool = true
    @State private var showingSettings = false
    @State private var listHeight: CGFloat = 0

    /// Tallest the list may grow before it starts scrolling.
    private let maxListHeight: CGFloat = 420

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
        .frame(width: 340)
        .sheet(isPresented: $showingSettings) {
            SettingsPanel(store: store, isPresented: $showingSettings)
        }
    }

    /// A plain VStack, not Lazy: the list is a handful of rows, so laziness
    /// buys nothing and only complicates layout.
    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(store.groups) { group in
                RepoSection(group: group)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claude Sessions")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            } else {
                Button {
                    store.refreshSoon()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No active sessions")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            FooterButton(title: "Settings…") { showingSettings = true }
            Spacer()
            FooterButton(title: "Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct RepoSection: View {
    let group: RepoGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(group.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(group.sessions.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 2)

            ForEach(group.sessions) { session in
                SessionRow(session: session, repoPath: group.path)
            }
        }
    }
}

struct SessionRow: View {
    let session: Session
    let repoPath: String
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(session.state.tint)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(session.age)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                Text(session.state.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(session.state.wantsAttention ? session.state.tint : .secondary)

                if !metadata.isEmpty {
                    Text(metadata)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
                .padding(.horizontal, 8)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(session.stateReason ?? session.state.label)
        .contextMenu {
            Button("Copy Resume Command") { copy(resumeCommand) }
            Button("Copy Path") { copy(Shell.quote(session.cwd ?? repoPath)) }
        }
    }

    private var metadata: String {
        var bits: [String] = []
        if let model = session.shortModel { bits.append(model) }
        if let context = session.contextLabel { bits.append(context) }
        if let branch = session.gitBranch, !branch.isEmpty, branch != "HEAD" { bits.append(branch) }
        return bits.joined(separator: " · ")
    }

    /// A command the owner pastes into a terminal. Every interpolated value --
    /// the working directory and the session id -- originates on the remote
    /// machine, so a compromised or shared host could otherwise smuggle shell
    /// metacharacters straight into a command the owner runs on their own Mac.
    /// Both are shell-quoted; `sessionId` is additionally validated at decode.
    private var resumeCommand: String {
        "cd \(Shell.quote(session.cwd ?? repoPath)) && claude --resume \(Shell.quote(session.sessionId))"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct SettingsPanel: View {
    @ObservedObject var store: SessionStore
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))

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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("\(store.collected) collected · \(store.hidden.count) hidden")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                ForEach(store.hidden) { item in
                    Text("• \(item.reason)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let error = store.lastError {
                    Text(error)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
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

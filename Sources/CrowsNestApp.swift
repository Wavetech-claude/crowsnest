import SwiftUI
import AppKit

/// Starts polling at launch.
///
/// SwiftUI does not construct a MenuBarExtra's state until it needs to
/// materialise the panel, so a store owned solely by the scene only began
/// polling once the user clicked -- exactly when the badge is no longer
/// useful. The delegate exists to break that dependency.
///
/// It deliberately does NOT own the store. Reaching through the delegate for
/// the scene's views left `MenuBarExtra`'s content closure without a properly
/// observed object: the label still updated, so the badge looked right, but
/// clicking it presented nothing. Both sides now share `SessionStore.shared`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let localNetworkPermission = LocalNetworkPermission()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SessionStore.shared
        // Must run before the first poll, and only in the real app -- the
        // offline preview renderer has its own entry point (PreviewRender)
        // and never calls this, but the guard keeps that explicit rather
        // than incidental.
        #if !PREVIEW
        localNetworkPermission.prime(host: store.host)
        #endif
        store.start()
    }
}

#if !PREVIEW
@main
#endif
struct CrowsNestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Owned by the scene so SwiftUI observes it; the same instance the
    /// delegate starts. @StateObject's autoclosure runs once, so this does
    /// not create a second store.
    @StateObject private var store = SessionStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar glyph. Monochrome by design -- macOS renders menu bar items as
/// template images, and a symbol that changes shape reads better at a glance
/// than a colour that gets flattened anyway.
private struct MenuBarLabel: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
        }
    }

    private var count: Int {
        store.attentionCount
    }

    private var symbol: String {
        switch store.worst {
        case .blocked: "exclamationmark.bubble.fill"   // needs approval
        case .waiting: "bubble.left.fill"              // your turn
        case .working: "bubble.left.and.text.bubble.right"
        default:       "bubble.left"
        }
    }
}

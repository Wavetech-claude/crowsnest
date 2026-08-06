#if PREVIEW
import SwiftUI
import AppKit

/// Offline renderer: rasterises the real MenuPanel to a PNG using the same
/// views the app ships, so the UI can be verified without a screen.
///
///     CrowsNestPreview <fixture.json> <out.png> [light|dark]
@main
struct PreviewRender {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data("usage: preview <fixture> <out.png> [light|dark]\n".utf8))
            exit(2)
        }
        let fixture = args[1]
        let output = args[2]
        let dark = args.count > 3 && args[3] == "dark"

        setenv("CROWSNEST_FIXTURE", fixture, 1)
        let result = await Collector.gather(host: "", includeLocal: false)
        let store = SessionStore(preloaded: result.groups)

        print("groups: \(result.groups.count)")
        for group in result.groups {
            print("  \(group.name)  (\(group.sessions.count))  worst=\(group.worst.rawValue)")
            for session in group.sessions {
                print("     \(session.state.rawValue.padded(9)) \(session.title.padded(14)) \(session.age)")
            }
        }

        let view = MenuPanel(store: store, scrolls: false)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color(white: 0.13) : Color(white: 0.97))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? data.write(to: URL(fileURLWithPath: output))
        print("wrote \(output) (\(image.width)x\(image.height))")
        exit(0)
    }
}

private extension String {
    func padded(_ n: Int) -> String {
        count >= n ? self : self + String(repeating: " ", count: n - count)
    }
}
#endif

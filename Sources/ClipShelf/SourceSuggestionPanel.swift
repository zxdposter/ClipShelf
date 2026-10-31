import AppKit
import SwiftUI

// A child panel can extend above the shelf without clipping or taking the search editor's focus.
struct SourceSuggestionPanel<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let visibleInSharing: Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.presented = isPresented
        view.panel.sharingType = visibleInSharing ? .readOnly : .none
        view.host.rootView = AnyView(content())
        view.positionPanel()
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.hidePanel() }

    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    final class Anchor: NSView {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        var presented = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.contentView = host
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); positionPanel() }
        override func layout() { super.layout(); positionPanel() }

        func hidePanel() {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        func positionPanel() {
            guard presented, let window else { hidePanel(); return }
            let anchor = window.convertToScreen(convert(bounds, to: nil))
            let size = host.fittingSize
            panel.setFrame(NSRect(x: anchor.minX, y: anchor.maxY + 8, width: size.width, height: size.height), display: true)
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
        }
    }
}

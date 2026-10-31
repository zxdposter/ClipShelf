import AppKit
import SwiftUI
import Testing
@testable import ClipShelf

struct SourceSuggestionPanelTests {
    @Test @MainActor func suggestionsStayAboveSearchWithoutTakingFocus() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 350), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = SourceSuggestionPanel<Text>.Anchor(frame: NSRect(x: 24, y: 300, width: 360, height: 32))
        defer { anchor.hidePanel(); window.close() }
        let content = try #require(window.contentView)
        content.addSubview(anchor)
        anchor.host.rootView = AnyView(Text("Application").frame(width: 360, height: 180))
        let responder = window.firstResponder
        anchor.presented = true
        anchor.positionPanel()
        let searchFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        #expect(anchor.panel.frame.minY == searchFrame.maxY + 8)
        #expect(anchor.panel.parent === window)
        #expect(!anchor.panel.canBecomeKey)
        #expect(window.firstResponder === responder)
        anchor.presented = false
        anchor.positionPanel()
        #expect(anchor.panel.parent == nil)
        #expect(!anchor.panel.isVisible)
    }
}

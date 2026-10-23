import AppKit
import SwiftUI

enum ShelfCardLayout {
    static let width: CGFloat = 256
    static let spacing: CGFloat = 16
    static let inset: CGFloat = 24

    static func navigationOffset(index: Int, count: Int, viewport: CGRect) -> CGFloat {
        guard (0..<count).contains(index), viewport.width > 0 else { return viewport.minX }
        let left = inset + CGFloat(index) * (width + spacing)
        let right = left + width
        let offset: CGFloat
        if viewport.width < width + inset * 2 || left < viewport.minX + inset { offset = left - inset }
        else if right > viewport.maxX - inset { offset = right + inset - viewport.width }
        else { return viewport.minX }
        let contentWidth = inset * 2 + CGFloat(count) * width + CGFloat(max(count - 1, 0)) * spacing
        return min(max(offset, 0), max(contentWidth - viewport.width, 0))
    }
}

// This anchor lives inside the scroll content, so it can reach the native clip view.
struct ShelfNavigationScroll: NSViewRepresentable {
    let index: Int?
    let count: Int
    let presentationID: UUID

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.update(index: index, count: count, presentationID: presentationID)
    }

    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        private var index: Int?
        private var count = 0
        private var presentationID: UUID?
        private var pendingIndex: Int?
        private var scheduled = false

        func update(index: Int?, count: Int, presentationID: UUID) {
            let reset = self.presentationID != presentationID
            let changed = self.index != index
            self.presentationID = presentationID
            self.index = index
            self.count = count
            guard reset || changed else { return }
            pendingIndex = reset ? 0 : index
            schedule()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule()
        }
        private func schedule() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.scrollIfNeeded()
            }
        }
        private func scrollIfNeeded() {
            guard let index = pendingIndex, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            let contentOrigin = convert(.zero, to: document).x
            let viewport = CGRect(x: clip.bounds.minX - contentOrigin, y: 0, width: clip.bounds.width, height: clip.bounds.height)
            let offset = ShelfCardLayout.navigationOffset(index: index, count: count, viewport: viewport) + contentOrigin
            pendingIndex = nil
            guard abs(offset - clip.bounds.minX) > 0.5 else { return }
            let bounds = clip.constrainBoundsRect(CGRect(origin: CGPoint(x: offset, y: clip.bounds.minY), size: clip.bounds.size))
            // Keyboard repeats must follow the latest selection, not restart an easing animation.
            clip.scroll(to: bounds.origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
}

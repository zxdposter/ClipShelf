import AppKit
import SwiftUI

struct ClipSharingPicker: NSViewRepresentable {
    @Binding var isPresented: Bool
    let items: () -> [Any]

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        guard isPresented, !view.pending else { return }
        view.pending = true
        // Context-menu builders run during ordinary card updates; discovery must wait for an explicit action.
        DispatchQueue.main.async {
            view.pending = false
            isPresented = false
            guard view.window != nil else { return }
            let values = items()
            guard !values.isEmpty else { return }
            let picker = NSSharingServicePicker(items: values)
            view.picker = picker
            picker.delegate = view
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    final class Anchor: NSView, NSSharingServicePickerDelegate {
        var pending = false
        var picker: NSSharingServicePicker?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            picker = nil
        }
    }
}

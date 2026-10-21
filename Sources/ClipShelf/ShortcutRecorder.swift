import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let binding: KeyBinding?
    let global: Bool
    let change: (KeyBinding?) -> Void
    let recordingChanged: (Bool) -> Void
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.isBordered = false
        button.target = button
        button.action = #selector(RecorderButton.beginRecording)
        return button
    }
    func updateNSView(_ view: RecorderButton, context: Context) {
        view.binding = binding; view.global = global; view.change = change; view.recordingChanged = recordingChanged
        if !view.recording { view.title = binding?.title ?? L("录制快捷键") }
        view.setAccessibilityLabel(L("快捷键：%@", binding?.title ?? L("未设置")))
    }
    static func dismantleNSView(_ view: RecorderButton, coordinator: ()) { view.finishRecording() }
    final class RecorderButton: NSButton {
        var binding: KeyBinding?
        var global = false
        var change: ((KeyBinding?) -> Void)?
        var recording = false
        var recordingChanged: ((Bool) -> Void)?
        private var keyObserver: NSObjectProtocol?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            guard let window else { finishRecording(); return }
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishRecording() }
            }
        }
        deinit { if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) } }
        @objc func beginRecording() { recording = true; recordingChanged?(true); title = L("按下快捷键…"); window?.makeFirstResponder(self) }
        func finishRecording() {
            if recording { recording = false; recordingChanged?(false) }
            title = binding?.title ?? L("录制快捷键")
        }
        override func resignFirstResponder() -> Bool { finishRecording(); return super.resignFirstResponder() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if recording { keyDown(with: event); return true }
            return super.performKeyEquivalent(with: event)
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
            if event.keyCode == 51 && KeyBinding.carbonModifiers(event.modifierFlags) == 0 { change?(nil); window?.makeFirstResponder(nil); return }
            let candidate = KeyBinding.from(event)
            guard !global || candidate.validGlobal else { NSSound.beep(); return }
            change?(candidate)
            window?.makeFirstResponder(nil)
        }
    }
}

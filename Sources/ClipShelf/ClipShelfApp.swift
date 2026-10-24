import AppKit
import SwiftUI
import Carbon
import QuartzCore
import ApplicationServices
import Combine
import ClipboardCore

@main
struct ClipShelfApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--check-accessibility") {
            let trusted = AXIsProcessTrusted()
            print(trusted ? "Accessibility: granted" : "Accessibility: not granted")
            exit(trusted ? 0 : 1)
        }
        if CommandLine.arguments.contains("--mcp") { MCPService.run(); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: ShelfPanel!
    private var settingsWindow: NSWindow?
    private var stackPanel: NSPanel?
    private var stackTap: CFMachPort?
    private var stackTapSource: CFRunLoopSource?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var modifierMonitor: Any?
    private var globalModifierMonitor: Any?
    private var statusItem: NSStatusItem!
    private var hotKeys: [ShortcutAction: EventHotKeyRef] = [:]
    private var privacyObserver: AnyCancellable?
    private var appearanceObserver: AnyCancellable?
    private var languageObserver: AnyCancellable?
    private var previousApplication: NSRunningApplication?
    private var eventHandler: EventHandlerRef?
    private var model: ClipboardModel!
    private var transitionID = 0
    private var hiding = false
    private var restingFrame = NSRect.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = ClipboardModel(demo: CommandLine.arguments.contains("--demo"))
        appearanceObserver = model.preferences.$appearance.sink { appearance in
            NSApp.appearance = appearance.nativeAppearance
        }
        model.onStackStarted = { [weak self] in self?.showStack() }
        installMainMenu()
        window = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "ClipShelf"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        installShelfContent()
        window.delegate = self
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideWindow() }
        }
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyUp]) { [weak self] event in
            if let self, self.window.isVisible {
                self.model.updateQuickPasteModifier(event.type == .keyUp ? NSEvent.modifierFlags : event.modifierFlags)
            }
            return event
        }
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.window.isVisible { self.model.updateQuickPasteModifier(event.modifierFlags) }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isVisible, (self.window.isKeyWindow || self.model.previewID != nil) else { return event }
            self.model.updateQuickPasteModifier(event.modifierFlags)
            let editor = (event.window?.firstResponder ?? self.window.firstResponder) as? NSTextView
            if editor?.hasMarkedText() == true { return event }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                self.showSettings(); return nil
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" { self.hideWindow(); return nil }
            if self.model.editingClipID != nil, event.keyCode != 53 { return event }
            if self.model.renamingID != nil, event.keyCode == 53 { self.model.renamingID = nil; self.window.makeFirstResponder(nil); return nil }
            if self.model.previewID != nil, event.keyCode == 53 || (event.keyCode == 49 && self.model.editingClipID == nil) {
                self.model.closePreview(); self.window.makeKey(); return nil
            }
            if event.keyCode == 53 {
                if self.model.creatingBoard || self.model.editingBoardID != nil { self.model.cancelBoardEdit() }
                else if self.model.searchShown {
                    self.model.clearSearch()
                    self.model.searchShown = false
                    self.window.makeFirstResponder(nil)
                } else { self.hideWindow() }
                return nil
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command), event.charactersIgnoringModifiers == "f" {
                if !self.model.searchShown { self.model.searchShown = true }
                self.focusSearch()
                return nil
            }
            if event.modifierFlags.contains([.command, .shift]), event.charactersIgnoringModifiers?.lowercased() == "n" {
                self.model.beginBoardEdit(); return nil
            }
            if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               self.model.renamingID == nil, !self.model.creatingBoard, self.model.editingBoardID == nil {
                self.model.moveSelection(event.modifierFlags.contains(.shift) ? -1 : 1)
                self.window.makeFirstResponder(nil)
                return nil
            }
            let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if self.model.quickPasteHeld, let index = digits[event.keyCode], let clip = self.model.quickPasteClip(number: index + 1) {
                self.paste([clip]); return nil
            }
            let isSearchEditor = editor != nil && self.model.searchField?.currentEditor() === editor
            if let editor, !isSearchEditor || self.model.searchShown {
                if event.modifierFlags.contains(.command) {
                    switch event.charactersIgnoringModifiers {
                    case "a": editor.selectAll(nil); return nil
                    case "c": editor.copy(nil); return nil
                    case "x": editor.cut(nil); return nil
                    case "v": editor.paste(nil); return nil
                    default: break
                    }
                }
                return event
            }
            if event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command,
               event.charactersIgnoringModifiers == "z" {
                self.model.undoDeletion(); return nil
            }
            if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                self.model.togglePreview(); return nil
            }
            if let next = self.model.preferences.binding(for: .nextBoard), next.matches(event) { self.model.advanceBoard(1); return nil }
            if let previous = self.model.preferences.binding(for: .previousBoard), previous.matches(event) { self.model.advanceBoard(-1); return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
                self.model.selection.selectAll(in: self.model.visible.map(\.id)); return nil
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
                self.model.copy(self.model.selectedClips); return nil
            }
            if let clip = self.model.visible.first(where: { $0.id == self.model.selectedID && self.model.selection.ids.contains($0.id) }) {
                if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "e" {
                    if clip.kind == .image { self.model.beginImageEdit(clip) }
                    else if [.text, .link].contains(clip.kind) { self.model.beginTextEdit(clip) }
                    return nil
                }
                if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "r" { self.model.beginRename(clip); return nil }
                if event.keyCode == 51 { self.model.remove(clip); return nil }
            }
            if event.keyCode == 36 {
                self.paste(self.model.selectedClips)
                return nil
            }
            if [123, 124].contains(event.keyCode) {
                self.model.moveSelection(event.keyCode == 124 ? 1 : -1, extending: event.modifierFlags.contains(.shift))
                return nil
            }
            if !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
               let text = event.charactersIgnoringModifiers, !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                if let field = self.model.searchField as? ShelfSearchField.SearchField, field.window === self.window {
                    if !self.model.searchShown { self.model.searchShown = true }
                    if field.beginTyping(with: event) { return nil }
                }
                return event
            }
            return event
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: L("ClipShelf 剪贴板历史"))
        installStatusMenu()
        languageObserver = AppLocalization.shared.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.installMainMenu()
                self.installStatusMenu()
                self.statusItem.button?.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: L("ClipShelf 剪贴板历史"))
                self.settingsWindow?.title = L("ClipShelf 设置")
                self.stackPanel?.title = L("顺序粘贴")
            }
        }
        if !model.demo { installGlobalShortcuts() }
        showWindow()
    }

    private func installStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L("打开 ClipShelf"), action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: L("设置…"), action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("退出 ClipShelf"), action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func installMainMenu() {
        let main = NSMenu()
        let app = NSMenu(title: "ClipShelf")
        let settings = app.addItem(withTitle: L("设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(.separator())
        let quit = app.addItem(withTitle: L("退出 ClipShelf"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        let edit = NSMenu(title: L("编辑"))
        for (title, selector, key) in [(L("撤销"), "undo:", "z"), (L("剪切"), "cut:", "x"), (L("复制"), "copy:", "c"), (L("粘贴"), "paste:", "v"), (L("全选"), "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        let windows = NSMenu(title: L("窗口"))
        windows.addItem(withTitle: L("关闭"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for menu in [app, edit, windows] {
            let item = NSMenuItem(); item.submenu = menu; main.addItem(item)
        }
        NSApp.mainMenu = main
    }
    private func installShelfContent() {
        window.contentView = NSHostingView(rootView: ShelfView(model: model,
            dismiss: { [weak self] in self?.hideWindow() },
            openSettings: { [weak self] in self?.showSettings() },
            enableCapture: { [weak self] in self?.enableCapture() },
            paste: { [weak self] clips, plain in self?.paste(clips, forcePlain: plain) }))
        privacyObserver = model.preferences.$showInScreenSharing.sink { [weak self] visible in
            self?.window?.sharingType = visible ? .readOnly : .none
            self?.settingsWindow?.sharingType = visible ? .readOnly : .none
            self?.stackPanel?.sharingType = visible ? .readOnly : .none
        }
    }
    private func enableCapture() {
        guard model.demo else { return }
        model = ClipboardModel()
        settingsWindow?.close(); settingsWindow = nil
        installShelfContent()
        installGlobalShortcuts()
        model.resetSelection()
    }
    @objc private func showSettings() {
        hideWindow()
        if settingsWindow == nil {
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
                                    styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            settings.title = L("ClipShelf 设置")
            settings.titleVisibility = .hidden
            settings.titlebarAppearsTransparent = true
            settings.isMovableByWindowBackground = true
            let toolbar = NSToolbar(identifier: "ClipShelf.Settings")
            toolbar.showsBaselineSeparator = false
            settings.toolbar = toolbar
            settings.toolbarStyle = .unified
            settings.sharingType = model.preferences.showInScreenSharing ? .readOnly : .none
            settings.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: SettingsView(model: model, preferences: model.preferences,
                changeShortcut: { [weak self] action, binding in self?.registerBinding(binding, for: action) },
                recordingChanged: { [weak self] recording in
                    guard let self, !self.model.demo else { return }
                    if recording { for hotKey in self.hotKeys.values { UnregisterEventHotKey(hotKey) }; self.hotKeys.removeAll() }
                    else { self.installGlobalShortcuts() }
                },
                enableCapture: { [weak self] in self?.enableCapture() }))
            hosting.sizingOptions = []
            settings.contentView = hosting
            settings.setFrame(NSRect(x: 0, y: 0, width: 820, height: 650), display: false)
            settings.center()
            settingsWindow = settings
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.settingsWindow?.makeFirstResponder(nil) }
    }
    private func showStack() {
        hideWindow()
        installStackTap()
        if stackPanel == nil {
            let panel = StackPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                                styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = L("顺序粘贴")
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.sharingType = model.preferences.showInScreenSharing ? .readOnly : .none
            panel.contentView = NSHostingView(rootView: StackView(model: model, openSettings: { [weak self] in self?.showSettings() }, finish: { [weak self] in
                self?.model.stackMode = false
                self?.stackPanel?.orderOut(nil)
            }))
            let screen = NSScreen.main?.visibleFrame ?? .zero
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 344, y: screen.midY - 200))
            stackPanel = panel
        }
        stackPanel?.orderFrontRegardless()
    }
    private func installStackTap() {
        guard AXIsProcessTrusted() else { model.stackPasteAvailable = false; return }
        if let stackTap { CGEvent.tapEnable(tap: stackTap, enable: true); model.stackPasteAvailable = true; return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                         callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = delegate.stackTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
                if type == .keyDown, modifiers == .maskCommand,
                   event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_V),
                   !delegate.window.isKeyWindow, delegate.settingsWindow?.isKeyWindow != true,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    if event.getIntegerValueField(.keyboardEventAutorepeat) != 0, delegate.model.stackMode { return nil }
                    // shortcut: advances on ⌘V, even if the destination cannot paste; add acknowledgement if recovery is needed.
                    // Write before delivering the original key event, so the destination reads this queue item.
                    delegate.model.prepareStackPaste()
                }
                return Unmanaged.passUnretained(event)
            }
        }, userInfo: context) else { return }
        stackTap = tap
        model.stackPasteAvailable = true
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        stackTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func installGlobalShortcuts() {
        if eventHandler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
                    if identifier.id == 2 {
                        delegate.model.startStack(includeSelection: delegate.window.isVisible)
                    } else {
                        delegate.showWindow()
                    }
                }
                return noErr
            }, 1, &event, nil, &eventHandler)
            guard installed == noErr else { model.message = L("无法安装快捷键处理器，请从菜单栏打开。"); return }
        }
        for action in ShortcutAction.allCases where action.isGlobal { registerBinding(model.preferences.binding(for: action), for: action, persist: false) }
    }
    private func registerBinding(_ binding: KeyBinding?, for action: ShortcutAction, persist: Bool = true) {
        if !action.isGlobal { model.preferences.setBinding(binding, for: action); return }
        guard let binding else {
            if let old = hotKeys.removeValue(forKey: action) { UnregisterEventHotKey(old) }
            if persist { model.preferences.setBinding(nil, for: action) }
            return
        }
        guard binding.validGlobal else { model.message = L("全局快捷键需要包含 Command、Option 或 Control。"); return }
        if hotKeys[action] != nil, let current = model.preferences.binding(for: action), current.keyCode == binding.keyCode, current.modifiers == binding.modifiers {
            if persist { model.preferences.setBinding(binding, for: action) }
            return
        }
        var next: EventHotKeyRef?
        let result = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                        EventHotKeyID(signature: 0x434C5348, id: action.eventID), GetApplicationEventTarget(), 0, &next)
        guard result == noErr else { model.message = L("%@ 已被占用，未更改原快捷键。", binding.title); return }
        if let old = hotKeys[action] { UnregisterEventHotKey(old) }
        hotKeys[action] = next
        if persist { model.preferences.setBinding(binding, for: action) }
        model.message = nil
    }
    private func paste(_ clips: [Clip], forcePlain: Bool = false) {
        guard !hiding else { return }
        let plain = forcePlain || model.preferences.alwaysPlainText || NSEvent.modifierFlags.contains(model.preferences.plainTextModifier.flag)
        guard model.copy(clips, plainText: plain) else { return }
        if !model.demo && model.preferences.soundEnabled { NSSound(named: "Pop")?.play() }
        let direct = !model.demo && model.preferences.pasteDestination == .activeApplication
        guard direct else { hideWindow(); return }
        guard AXIsProcessTrusted() else {
            model.message = L("内容已复制。直接粘贴需要在系统设置→隐私与安全性→辅助功能中允许 ClipShelf。")
            hideWindow { [weak self] in
                let alert = directPastePermissionAlert()
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                } else {
                    self?.previousApplication?.activate(options: [])
                }
            }
            return
        }
        guard let destination = previousApplication, !destination.isTerminated else {
            model.message = L("内容已复制，目标应用不可用，请手动粘贴。")
            hideWindow(); return
        }
        hideWindow {
            guard destination.activate(options: []) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier, AXIsProcessTrusted() else { return }
                let down = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_ANSI_V), keyDown: true)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_ANSI_V), keyDown: false)
                down?.flags = .maskCommand; up?.flags = .maskCommand
                down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
            }
        }
    }

    private func focusSearch() {
        guard let field = model.searchField, field.window === window,
              field.currentEditor() !== window.firstResponder else { return }
        (field as? ShelfSearchField.SearchField)?.focusForSearch()
    }

    @objc func showWindow() {
        if window.isVisible && !hiding { hideWindow(); return }
        if let source = NSWorkspace.shared.frontmostApplication, source.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = source }
        transitionID += 1
        hiding = false
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        restingFrame = ShelfGeometry.shown(in: screen.frame)
        model.updateQuickPasteModifier(NSEvent.modifierFlags)
        model.pasteTargetName = previousApplication?.localizedName ?? L("当前应用")
        model.resetSelection()
        model.presentationID = UUID()
        window.setFrame(ShelfGeometry.hidden(from: restingFrame), display: false)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        animate(to: restingFrame, alpha: 1)

    }
    private func animate(to frame: NSRect, alpha: CGFloat, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = alpha
        } completionHandler: { completion?() }
    }
    private func hideWindow(completion: (() -> Void)? = nil) {
        guard window.isVisible, !hiding else { completion?(); return }
        model.updateQuickPasteModifier([])
        model.closePreview()
        model.renamingID = nil
        hiding = true
        transitionID += 1
        let current = transitionID
        animate(to: ShelfGeometry.hidden(from: restingFrame), alpha: 0) { [weak self] in
            guard let self, self.transitionID == current else { return }
            self.window.orderOut(nil)
            self.hiding = false
            self.model.searchShown = false
            self.model.clearSearch()
            self.model.cancelBoardEdit()
            completion?()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !window.isVisible && !(settingsWindow?.isVisible ?? false) { showWindow() }
        return true
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideWindow(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        if let globalModifierMonitor { NSEvent.removeMonitor(globalModifierMonitor) }
        if let stackTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), stackTapSource, .commonModes) }
        if let stackTap { CFMachPortInvalidate(stackTap) }
        for hotKey in hotKeys.values { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

private final class StackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum ShelfGeometry {
    static func shown(in screen: NSRect) -> NSRect {
        NSRect(x: screen.minX + 16, y: screen.minY + 16, width: max(0, screen.width - 32), height: max(0, min(352, screen.height - 32)))
    }
    static func hidden(from frame: NSRect) -> NSRect { frame.offsetBy(dx: 0, dy: -18) }
}

@MainActor func directPastePermissionAlert() -> NSAlert {
    let alert = NSAlert()
    alert.messageText = L("允许 ClipShelf 直接粘贴")
    alert.informativeText = L("内容已复制。直接粘贴需要辅助功能权限。请在系统设置的“隐私与安全性”中找到“辅助功能”（部分系统显示为“设备控制与数据访问”），开启 ClipShelf。\n\n若列表中没有 ClipShelf，请点击 + 添加 /Applications/ClipShelf.app。也可以稍后设置，先返回目标应用按 ⌘V 粘贴。")
    alert.alertStyle = .informational
    alert.addButton(withTitle: L("打开系统设置"))
    alert.addButton(withTitle: L("稍后"))
    return alert
}

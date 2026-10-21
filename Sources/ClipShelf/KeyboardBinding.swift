import AppKit
import Carbon

enum ShortcutAction: String, CaseIterable, Identifiable {
    case activate, stack, nextBoard, previousBoard
    var id: Self { self }
    var title: String {
        switch self {
        case .activate: L("启动 ClipShelf")
        case .stack: L("启动顺序粘贴")
        case .nextBoard: L("下一个收藏集")
        case .previousBoard: L("上一个收藏集")
        }
    }
    var isGlobal: Bool { self == .activate || self == .stack }
    var eventID: UInt32 { self == .activate ? 1 : 2 }
    var defaultBinding: KeyBinding {
        switch self {
        case .activate: KeyBinding(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), key: "V")
        case .stack: KeyBinding(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey), key: "C")
        case .nextBoard: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(cmdKey), key: "→")
        case .previousBoard: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(cmdKey), key: "←")
        }
    }
}

struct KeyBinding: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let key: String
    var title: String {
        [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined() + key
    }
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
    func matches(_ event: NSEvent) -> Bool { keyCode == event.keyCode && modifiers == Self.carbonModifiers(event.modifierFlags) }
    var validGlobal: Bool { modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 }
    static func from(_ event: NSEvent) -> KeyBinding {
        let names: [UInt16: String] = [UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓", UInt16(kVK_Return): "↩", UInt16(kVK_Space): "Space", UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫"]
        return KeyBinding(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers(event.modifierFlags), key: names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
    }
}

enum KeyModifier: String, CaseIterable, Identifiable {
    case command, option, control, shift
    var id: Self { self }
    var title: String {
        switch self { case .command: "⌘ Command"; case .option: "⌥ Option"; case .control: "⌃ Control"; case .shift: "⇧ Shift" }
    }
    var flag: NSEvent.ModifierFlags {
        switch self { case .command: .command; case .option: .option; case .control: .control; case .shift: .shift }
    }
}

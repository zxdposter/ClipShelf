import AppKit
import SwiftUI
import ClipboardCore

private final class FormattedText: NSObject {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}
private let richTextCache: NSCache<NSData, FormattedText> = {
    let cache = NSCache<NSData, FormattedText>()
    cache.countLimit = 64
    cache.totalCostLimit = 16 * 1024 * 1024
    return cache
}()

func formattedClipText(_ clip: Clip) -> AttributedString {
    if let data = clip.items.flatMap({ $0 }).first(where: { $0.type == "public.rtf" })?.data {
        let key = data as NSData
        if let cached = richTextCache.object(forKey: key) { return cached.value }
        guard let rich = NSAttributedString(rtf: data, documentAttributes: nil) else { return AttributedString(clip.text) }
        let readable = NSMutableAttributedString(attributedString: rich)
        // Default black text needs to follow appearance; explicit colors and backgrounds stay intact.
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attributes, range, _ in
            guard attributes[.backgroundColor] == nil,
                  let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB),
                  color.redComponent < 0.05, color.greenComponent < 0.05, color.blueComponent < 0.05 else { return }
            readable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }
        let text = AttributedString(readable)
        richTextCache.setObject(FormattedText(text), forKey: key, cost: data.count * 4)
        return text
    }
    return AttributedString(clip.text)
}


func cardClipText(_ clip: Clip) -> AttributedString {
    guard clip.items.contains(where: { $0.contains(where: { $0.type == "public.rtf" }) }) else {
        return AttributedString(String(clip.text.prefix(1200)))
    }
    let text = formattedClipText(clip)
    let end = text.characters.index(text.startIndex, offsetBy: 1200, limitedBy: text.endIndex) ?? text.endIndex
    return AttributedString(text[..<end])
}

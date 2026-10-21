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
        let text = AttributedString(rich)
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

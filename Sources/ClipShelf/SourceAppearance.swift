import AppKit

@MainActor
struct SourceAppearance {
    let icon: NSImage
    let color: NSColor
    private static var cache: [String: SourceAppearance] = [:]
    static func forApp(_ bundle: String, fallback: String) -> SourceAppearance {
        let key = bundle.isEmpty ? fallback : bundle
        if let cached = cache[key] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)!
        let appearance = SourceAppearance(icon: icon, color: representativeColor(of: icon))
        cache[key] = appearance
        return appearance
    }
}

@MainActor func representativeColor(of icon: NSImage) -> NSColor {
    guard let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: pixels) else { return .secondaryLabelColor }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    icon.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
    NSGraphicsContext.restoreGraphicsState()
    var bins = Array(repeating: (weight: CGFloat(0), red: CGFloat(0), green: CGFloat(0), blue: CGFloat(0)), count: 12)
    for y in 0..<24 {
        for x in 0..<24 {
            guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            guard alpha > 0.5, saturation > 0.18, brightness > 0.15 else { continue }
            let index = min(11, Int(hue * 12))
            let weight = saturation * alpha
            bins[index].weight += weight
            bins[index].red += color.redComponent * weight
            bins[index].green += color.greenComponent * weight
            bins[index].blue += color.blueComponent * weight
        }
    }
    guard let best = bins.max(by: { $0.weight < $1.weight }), best.weight > 0 else { return .secondaryLabelColor }
    return NSColor(deviceRed: best.red / best.weight, green: best.green / best.weight, blue: best.blue / best.weight, alpha: 1)
}

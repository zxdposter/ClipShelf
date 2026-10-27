import AppKit
import SwiftUI

struct ClipColor {
    let value: UInt32
    private var red: Double { Double((value >> 16) & 255) / 255 }
    private var green: Double { Double((value >> 8) & 255) / 255 }
    private var blue: Double { Double(value & 255) / 255 }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    var hex: String { String(format: "#%06X", value) }
    var usesLightText: Bool {
        let linear = [red, green, blue].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let luminance = linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        return 1.05 / (luminance + 0.05) >= (luminance + 0.05) / 0.05
    }
    var textColor: Color { usesLightText ? .white : .black }
    var summary: String {
        let native = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        let hue = Int((native.hueComponent * 360).rounded()) % 360
        let lightness = (max(red, green, blue) + min(red, green, blue)) / 2
        let saturation = lightness == 0 || lightness == 1 ? 0 : (max(red, green, blue) - min(red, green, blue)) / (1 - abs(2 * lightness - 1))
        return "RGB \((value >> 16) & 255), \((value >> 8) & 255), \(value & 255) · HSL \(hue), \(Int((saturation * 100).rounded())), \(Int((lightness * 100).rounded())) · HSB \(hue), \(Int((native.saturationComponent * 100).rounded())), \(Int((native.brightnessComponent * 100).rounded()))"
    }
}

struct ColorClipPreview: View {
    let color: ClipColor
    var body: some View {
        ZStack {
            color.color
            Text(color.hex).font(.system(size: 36, weight: .medium, design: .monospaced))
                .foregroundStyle(color.textColor).textSelection(.enabled)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import AppKit
import SwiftUI
import ClipboardCore

enum ShelfDesign {
    static let accent = Color(nsColor: adaptive(light: (0.22, 0.25, 0.30), dark: (0.78, 0.82, 0.88)))
    static let selection = Color(nsColor: adaptive(light: (0.36, 0.44, 0.54), dark: (0.64, 0.73, 0.84)))
    static let canvas = Color(nsColor: adaptive(light: (0.86, 0.88, 0.91), dark: (0.08, 0.09, 0.11)))
    static let card = Color(nsColor: adaptive(light: (1, 1, 1), dark: (0.13, 0.145, 0.17)))
    static let paper = Color(nsColor: adaptive(light: (0.97, 0.975, 0.985), dark: (0.16, 0.18, 0.21)))
    static let line = Color(nsColor: adaptive(light: (0.68, 0.71, 0.76), dark: (0.33, 0.36, 0.41))).opacity(0.45)
    static let edge = Color(nsColor: adaptive(light: (1, 1, 1), dark: (0.68, 0.72, 0.78))).opacity(0.45)
    static func typeColor(_ kind: ClipKind) -> Color {
        switch kind {
        case .text: accent
        case .link: Color(nsColor: adaptive(light: (0.29, 0.39, 0.54), dark: (0.58, 0.69, 0.84)))
        case .image: Color(nsColor: adaptive(light: (0.44, 0.38, 0.51), dark: (0.72, 0.65, 0.79)))
        case .files: Color(nsColor: adaptive(light: (0.48, 0.39, 0.28), dark: (0.77, 0.68, 0.54)))
        }
    }
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
}

struct ShelfGlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if reduceTransparency { ShelfDesign.canvas }
            else {
                ShelfVisualEffect()
                ShelfDesign.canvas.opacity(0.16)
                LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct ShelfVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 22
        view.layer?.masksToBounds = true
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ShelfMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(ShelfDesign.accent)
            RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.55), lineWidth: 1.5).frame(width: 15, height: 18).offset(x: -3, y: -3)
            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.95)).frame(width: 15, height: 18).offset(x: 3, y: 3)
            Capsule().fill(ShelfDesign.accent).frame(width: 8, height: 1.5).offset(x: 3, y: 3)
        }.frame(width: 34, height: 34).accessibilityHidden(true)
    }
}

struct ShelfIllustration: View {
    var searching = false
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 200, size.height / 130)
            context.translateBy(x: (size.width - 200 * scale) / 2, y: (size.height - 130 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.fill(Path(ellipseIn: CGRect(x: 24, y: 108, width: 152, height: 12)), with: .color(ShelfDesign.accent.opacity(0.08)))
            context.fill(Path(ellipseIn: CGRect(x: 12, y: 18, width: 60, height: 60)), with: .color(ShelfDesign.accent.opacity(0.08)))
            var back = context
            back.translateBy(x: 58, y: 58); back.rotate(by: .degrees(-12))
            back.fill(Path(roundedRect: CGRect(x: -34, y: -37, width: 68, height: 84), cornerRadius: 10), with: .color(ShelfDesign.accent.opacity(0.20)))
            var front = context
            front.translateBy(x: 108, y: 61); front.rotate(by: .degrees(8))
            let paper = Path(roundedRect: CGRect(x: -38, y: -42, width: 76, height: 94), cornerRadius: 10)
            front.fill(paper, with: .color(ShelfDesign.paper))
            front.stroke(paper, with: .color(ShelfDesign.accent.opacity(0.25)), lineWidth: 1)
            for row in 0..<3 {
                front.fill(Path(roundedRect: CGRect(x: -24, y: CGFloat(row) * 12 - 10, width: row == 2 ? 28 : 46, height: 4), cornerRadius: 2), with: .color(ShelfDesign.accent.opacity(row == 0 ? 0.55 : 0.18)))
            }
            if searching {
                context.stroke(Path(ellipseIn: CGRect(x: 135, y: 65, width: 32, height: 32)), with: .color(ShelfDesign.accent), lineWidth: 5)
                var handle = Path(); handle.move(to: CGPoint(x: 162, y: 93)); handle.addLine(to: CGPoint(x: 176, y: 108))
                context.stroke(handle, with: .color(ShelfDesign.accent), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            } else {
                context.fill(Path(ellipseIn: CGRect(x: 144, y: 77, width: 26, height: 26)), with: .color(ShelfDesign.accent))
                var check = Path(); check.move(to: CGPoint(x: 151, y: 90)); check.addLine(to: CGPoint(x: 156, y: 95)); check.addLine(to: CGPoint(x: 164, y: 85))
                context.stroke(check, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }.accessibilityHidden(true)
    }
}


struct CardDragPreview: View {
    let clip: Clip
    let count: Int
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: count > 1 ? "square.stack.fill" : clip.kind.symbol)
                .font(.system(size: 16, weight: .medium)).foregroundStyle(ShelfDesign.accent)
                .frame(width: 28, height: 28)
                .background(ShelfDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(count > 1 ? L("%@ 张卡片", count) : (clip.title ?? clip.text))
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(L("拖入收藏集")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "plus.circle.fill").foregroundStyle(ShelfDesign.accent)
        }.padding(8).frame(width: 184, height: 48)
            .background(ShelfDesign.paper, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ShelfDesign.accent.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 3)
            // Keep the preview below the pointer so the collection under it stays visible.
            .padding(.top, 36).padding(.horizontal, 6).padding(.bottom, 8)
    }
}


func boardColorSwatch(_ color: Color, selected: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
        NSColor(color).setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14)).fill()
        if selected {
            NSColor.white.setStroke()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: 4, y: 8)); tick.line(to: NSPoint(x: 7, y: 5)); tick.line(to: NSPoint(x: 12, y: 11))
            tick.lineWidth = 1.7; tick.lineCapStyle = .round; tick.lineJoinStyle = .round; tick.stroke()
        }
        return true
    }
    image.isTemplate = false
    return image
}

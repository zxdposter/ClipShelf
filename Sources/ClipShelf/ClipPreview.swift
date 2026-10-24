import AppKit
import SwiftUI
import ClipboardCore
import Quartz

struct ClipPreview: View {
    @ObservedObject private var localization = AppLocalization.shared
    let clip: Clip
    @ObservedObject var model: ClipboardModel
    let close: () -> Void
    private var webURL: URL? { clip.kind == .link ? safeLinkURL(clip) : nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel(L("关闭预览"))
                Label(clip.title ?? clip.kind.label, systemImage: clip.kind.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(ShelfDesign.accent)
                Spacer()
                if model.editingClipID == clip.id {
                    Button(L("取消")) { model.cancelTextEdit() }
                    Button(L("完成")) { model.finishTextEdit() }.disabled(model.removingBackground)
                }
            }.buttonStyle(.plain).padding(12)
            Divider()
            if model.editingClipID == clip.id, clip.kind == .image, let data = model.imageDraft, let image = NSImage(data: data) {
                HStack {
                    Button { model.rotateImage(clockwise: false) } label: { Image(systemName: "rotate.left") }.help(L("向左旋转"))
                    Button { model.rotateImage(clockwise: true) } label: { Image(systemName: "rotate.right") }.help(L("向右旋转"))
                    Button(L("移除背景")) { model.removeImageBackground() }
                    Button(L("恢复背景")) { model.imageDraft = model.imageOriginal }
                }.disabled(model.removingBackground).padding(8)
                if model.removingBackground { ProgressView(L("正在移除背景…")).controlSize(.small) }
                Image(nsImage: image).resizable().scaledToFit().padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.editingClipID == clip.id {
                TextEditor(text: $model.editDraft).font(.system(size: 14)).padding(8)
            } else if clip.kind == .image, let data = clip.items.flatMap({ $0 }).first(where: { ["public.png", "public.tiff"].contains($0.type) })?.data,
               let image = NSImage(data: data) {
                HighlightedClipImage(image: image, highlights: model.imageTextHighlights(for: clip), selectionIdentity: clip.fingerprint).padding(12)
            } else if clip.kind == .files, let url = previewFileURL(clip) {
                FileQuickPreview(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let url = webURL {
                WebPagePreview(url: url).id(url)
            } else {
                ScrollView { Text(formattedClipText(clip)).font(.system(size: 14)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(12) }
            }
            Divider()
            Text(clip.kind == .text || clip.kind == .link ? previewStatistics(clip.text) : Int64(clip.byteCount).formatted(.byteCount(style: .file).locale(Locale(identifier: AppLocalization.shared.language.rawValue))))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.frame(width: webURL == nil ? 660 : 900, height: webURL == nil ? 450 : 620).background(ShelfDesign.paper).tint(ShelfDesign.accent)
    }
}

struct HighlightedClipImage: View {
    let image: NSImage
    let highlights: [CGRect]
    var selectionIdentity: String? = nil
    var body: some View {
        Group {
            if let identity = selectionIdentity { LiveTextImage(image: image, identity: identity) }
            else { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
            .overlay {
                GeometryReader { geometry in
                    ForEach(Array(highlights.enumerated()), id: \.offset) { _, box in
                        let rect = imageTextHighlightFrame(box, image: image.size, container: geometry.size)
                        RoundedRectangle(cornerRadius: 2).fill(Color.yellow.opacity(0.3))
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.orange.opacity(0.6), lineWidth: 0.5))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

func imageTextHighlightFrame(_ box: CGRect, image: CGSize, container: CGSize) -> CGRect {
    guard image.width > 0, image.height > 0 else { return .zero }
    let scale = min(container.width / image.width, container.height / image.height)
    let width = image.width * scale, height = image.height * scale
    // Vision uses a bottom-left origin; SwiftUI positions from the top-left.
    return CGRect(x: (container.width - width) / 2 + box.minX * width,
                  y: (container.height - height) / 2 + (1 - box.maxY) * height,
                  width: box.width * width, height: box.height * height)
}

func previewStatistics(_ text: String) -> String {
    var words = 0
    text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, _, _, _ in words += 1 }
    let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
    return L("%@ 个字符 · %@ 单词 · %@ 行", text.count, words, lines)
}

// shortcut: file bundles preview the first existing file; add a navigator when multi-file preview is needed.
func previewFileURL(_ clip: Clip) -> URL? {
    filePreviewURLs(clip).first { FileManager.default.fileExists(atPath: $0.path) }
}

func filePreviewURLs(_ clip: Clip) -> [URL] {
    clip.items.flatMap { $0 }.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
        .compactMap { String(data: $0.data, encoding: .utf8).flatMap(URL.init(string:)) }
        .filter { $0.isFileURL }
}

private struct FileQuickPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .normal)! }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

// The popover owns a separate window, so it must inherit the shelf's sharing policy.
struct PreviewPrivacy: NSViewRepresentable {
    let visible: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.sharingType = visible ? .readOnly : .none }
    }
}

func safeLinkURL(_ clip: Clip) -> URL? {
    guard let url = URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return url
}

func sharingItems(_ clips: [Clip]) -> [Any] {
    clips.flatMap { clip -> [Any] in
        if clip.kind == .files { return filePreviewURLs(clip) }
        if clip.kind == .image, let data = clip.items.flatMap({ $0 }).first(where: { ["public.png", "public.tiff"].contains($0.type) })?.data,
           let image = NSImage(data: data) { return [image] }
        if clip.kind == .link, let url = safeLinkURL(clip) { return [url] }
        return [clip.text]
    }
}

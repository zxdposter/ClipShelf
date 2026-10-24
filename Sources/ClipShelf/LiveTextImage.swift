import AppKit
import SwiftUI
import VisionKit

struct LiveTextImage: NSViewRepresentable {
    let image: NSImage
    let identity: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> LiveTextImageView { LiveTextImageView() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LiveTextImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 636, height: proposal.height ?? 340)
    }
    func updateNSView(_ view: LiveTextImageView, context: Context) {
        guard context.coordinator.identity != identity else { return }
        context.coordinator.identity = identity
        context.coordinator.task?.cancel()
        view.imageView.image = image; view.overlay.analysis = nil
        view.needsLayout = true
        guard ImageAnalyzer.isSupported else { view.status.stringValue = L("此设备不支持图片文字选择"); return }
        view.status.stringValue = L("正在识别图片文字…"); view.status.isHidden = false
        context.coordinator.task = Task(priority: .background) { [weak view] in
            do {
                var configuration = ImageAnalyzer.Configuration(.text)
                configuration.locales = ["zh-Hans", "zh-Hant", "en-US"]
                let analysis = try await ImageAnalyzer().analyze(image, orientation: .up, configuration: configuration)
                guard !Task.isCancelled, let view else { return }
                view.overlay.analysis = analysis
                view.overlay.selectableItemsHighlighted = false
                view.status.stringValue = L("未识别到可选择的文字")
                view.status.isHidden = analysis.hasResults(for: .text)
            } catch {
                guard !Task.isCancelled else { return }
                view?.status.stringValue = L("图片文字识别失败，请重新打开预览")
            }
        }
    }
    static func dismantleNSView(_ view: LiveTextImageView, coordinator: Coordinator) {
        coordinator.task?.cancel(); coordinator.task = nil
        view.overlay.analysis = nil
    }
    @MainActor final class Coordinator {
        var identity: String?
        var task: Task<Void, Never>?
    }
}

final class LiveTextImageView: NSView {
    let imageView = NSImageView()
    let overlay = ImageAnalysisOverlayView()
    let status = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        overlay.trackingImageView = imageView
        overlay.preferredInteractionTypes = .textSelection
        overlay.isSupplementaryInterfaceHidden = true
        addSubview(overlay)
        status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabelColor
        addSubview(status)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        var imageRect = bounds
        if let size = imageView.image?.size, size.width > 0, size.height > 0 {
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let width = size.width * scale, height = size.height * scale
            imageRect = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        }
        // Keep VisionKit coordinates on the displayed image, excluding aspect-fit margins.
        imageView.frame = imageRect; overlay.frame = imageRect
        overlay.setContentsRectNeedsUpdate()
        status.frame = CGRect(x: 8, y: 6, width: max(0, bounds.width - 16), height: 16)
    }
    func selectAllText() {
        let text = overlay.text
        if !text.isEmpty { overlay.selectedRanges = [text.startIndex..<text.endIndex] }
    }
    @discardableResult func copySelectedText(to pasteboard: NSPasteboard) -> Bool {
        let text = overlay.selectedText
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
    static func find(in view: NSView?) -> LiveTextImageView? {
        guard let view else { return nil }
        if let image = view as? LiveTextImageView { return image }
        for child in view.subviews { if let image = find(in: child) { return image } }
        return nil
    }
}

import AppKit
import Testing
import SwiftUI
import LinkPresentation
import ClipboardCore
import WebKit
import Network
@testable import ClipShelf

struct PreviewTests {
    @Test func webPreviewOnlyAllowsWebAddresses() {
        for address in ["https://example.com/article", "http://127.0.0.1:1234/page"] {
            #expect(allowsWebPreviewNavigation(URL(string: address)))
        }
        for address in ["file:///tmp/private.txt", "javascript:alert(1)", "data:text/html,example", "my-app://open", "https://user:password@example.com"] {
            #expect(!allowsWebPreviewNavigation(URL(string: address)))
        }
        #expect(!allowsWebPreviewNavigation(nil))
    }
    @Test @MainActor func webPreviewLoadsScrollablePageWithoutUsingBrowserSession() async throws {
        let html = "<html><head><title>Preview fixture</title></head><body style='height:2400px'><h1>网页正文测试</h1><p>LOCAL_PAGE_CONTENT_2026</p></body></html>"
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)".utf8)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "ClipShelf-preview-fixture")
        server.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        server.start(queue: queue)
        defer { server.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while (server.port?.rawValue ?? 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let port = try #require(server.port)
        try #require(port.rawValue > 0)
        let address = "http://127.0.0.1:\(port.rawValue)/article"
        let clip = Clip(kind: .link, text: address, sourceName: "Test", sourceBundle: "", items: [], identity: Data(address.utf8))
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        model.history = History(clips: [clip]); model.previewID = clip.id
        #expect(model.previewingWebPage)
        model.editingClipID = clip.id
        #expect(!model.previewingWebPage)
        model.editingClipID = nil
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: ClipPreview(clip: clip, model: model, close: {}))
        window.contentView = host; host.layoutSubtreeIfNeeded()
        func browsers(_ view: NSView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(browsers)
        }
        let web = try #require(browsers(host).first)
        var body = ""
        while ContinuousClock.now < deadline {
            body = (try? await web.evaluateJavaScript("document.body.innerText")) as? String ?? ""
            if body.contains("LOCAL_PAGE_CONTENT_2026") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(body.contains("网页正文测试") && body.contains("LOCAL_PAGE_CONTENT_2026"))
        #expect(!web.configuration.websiteDataStore.isPersistent)
        #expect(web.frame.width >= 600 && web.frame.height >= 300)
        let scrollable = try await web.evaluateJavaScript("document.documentElement.scrollHeight > window.innerHeight") as? Bool
        #expect(scrollable == true)
        let scrollY = try await web.evaluateJavaScript("window.scrollTo(0, 600); window.scrollY") as? Double
        #expect((scrollY ?? 0) > 0)
        let blocked = WebPageState(url: URL(fileURLWithPath: "/tmp/private.txt"))
        blocked.load()
        #expect(blocked.failure != nil && !blocked.loading && blocked.webView.url == nil)
    }
    @Test @MainActor func linkMetadataCannotEnlargeClipboardCard() async throws {
        let url = URL(string: "https://example.invalid/preview")!
        let preferences = isolatedPreferences(); preferences.linkPreviews = true
        let model = ClipboardModel(demo: true, preferences: preferences)
        let link = Clip(kind: .link, text: url.absoluteString, sourceName: "Test", sourceBundle: "",
                        items: [], identity: Data(url.absoluteString.utf8))
        model.history = History(clips: [link]); model.resetSelection()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 352), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: ShelfView(model: model, dismiss: {}, openSettings: {}, enableCapture: {}, paste: { _, _ in }))
        window.contentView = host; host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func links(_ view: NSView) -> [LPLinkView] {
            (view as? LPLinkView).map { [$0] } ?? view.subviews.flatMap(links)
        }
        let native = try #require(links(host).first)
        let metadata = LPLinkMetadata(); metadata.originalURL = url; metadata.url = url
        metadata.title = String(repeating: "A long repository title ", count: 8)
        let image = NSImage(size: CGSize(width: 1800, height: 900), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        metadata.imageProvider = NSItemProvider(object: image)
        native.metadata = metadata
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let frame = native.convert(native.bounds, to: host)
        #expect(frame.width > 0 && frame.width <= ShelfCardLayout.width - 28)
        #expect(frame.height > 0 && frame.height <= ShelfCardLayout.height - 28)
        #expect(host.bounds.contains(frame))
    }
    @Test func imageHighlightsFollowAspectFitAndVisionCoordinates() {
        let box = CGRect(x: 0.1, y: 0.6, width: 0.3, height: 0.2)
        let wide = imageTextHighlightFrame(box, image: CGSize(width: 1000, height: 500), container: CGSize(width: 600, height: 400))
        #expect(abs(wide.minX - 60) < 0.001 && abs(wide.minY - 110) < 0.001)
        #expect(abs(wide.width - 180) < 0.001 && abs(wide.height - 60) < 0.001)
        let tall = imageTextHighlightFrame(box, image: CGSize(width: 500, height: 1000), container: CGSize(width: 600, height: 400))
        #expect(abs(tall.minX - 220) < 0.001 && abs(tall.minY - 80) < 0.001)
        #expect(abs(tall.width - 60) < 0.001 && abs(tall.height - 80) < 0.001)
        #expect(imageTextHighlightFrame(box, image: .zero, container: CGSize(width: 600, height: 400)) == .zero)
    }
    @Test @MainActor func spacePreviewUsesFocusedSelectedCardAndDoesNotCopy() throws {
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        model.resetSelection()
        let id = try #require(model.selectedID)
        model.togglePreview()
        #expect(model.previewID == id)
        #expect(model.copiedID == nil)
        model.togglePreview()
        #expect(model.previewID == nil)
        model.selection.selectAll(in: model.visible.map(\.id))
        model.togglePreview()
        #expect(model.previewID == id)
        model.resetSelection()
        #expect(model.previewID == nil)
        model.selection = .init()
        model.togglePreview()
        #expect(model.previewID == nil)
    }
    @Test @MainActor func appColorIgnoresNeutralAndTransparentPixels() throws {
        let icon = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 24, height: 24).fill()
            NSColor.systemRed.setFill(); NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        let color = try #require(representativeColor(of: icon).usingColorSpace(.deviceRGB))
        #expect(color.redComponent > color.greenComponent * 2)
        #expect(color.redComponent > color.blueComponent * 2)
        let empty = NSImage(size: NSSize(width: 24, height: 24))
        #expect(representativeColor(of: empty) == .secondaryLabelColor)
    }
    @Test func textStatisticsPreserveLineBreaks() {
        #expect(previewStatistics("") == "0 个字符 · 0 单词 · 0 行")
        #expect(previewStatistics("hello world\nnext") == "16 个字符 · 3 单词 · 2 行")
    }
}

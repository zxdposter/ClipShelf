import SwiftUI
import WebKit

func allowsWebPreviewNavigation(_ url: URL?) -> Bool {
    guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
    return true
}

struct WebPagePreview: View {
    @StateObject private var page: WebPageState
    init(url: URL) { _page = StateObject(wrappedValue: WebPageState(url: url)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { page.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!page.canGoBack).help(L("返回上一页"))
                Button { page.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!page.canGoForward).help(L("前往下一页"))
                Text(page.webView.url?.host ?? page.url.host ?? "").font(.system(size: 12)).lineLimit(1)
                Spacer()
                if page.loading { ProgressView().controlSize(.small).accessibilityLabel(L("正在加载网页…")) }
                Button { page.load() } label: { Image(systemName: "arrow.clockwise") }.help(L("重试"))
                Button {
                    let url = page.webView.url ?? page.url
                    if allowsWebPreviewNavigation(url) { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "arrow.up.right.square") }
                    .help(L("在默认浏览器中打开"))
            }.buttonStyle(.plain).padding(10)
            Divider()
            ZStack {
                WebPageContent(page: page)
                if let failure = page.failure {
                    VStack(spacing: 12) {
                        Image(systemName: "network.slash").font(.title)
                        Text(L("网页加载失败")).font(.headline)
                        Text(failure).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(L("重试")) { page.load() }
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(ShelfDesign.paper)
                }
            }
        }.clipped()
    }
}

@MainActor final class WebPageState: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let url: URL
    let webView: WKWebView
    @Published var loading = true
    @Published var failure: String?
    @Published var canGoBack = false
    @Published var canGoForward = false
    init(url: URL) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
    }
    func load() {
        let target = webView.url ?? url
        guard allowsWebPreviewNavigation(target) else { loading = false; failure = L("网页无法在预览中显示，请在浏览器中打开。"); return }
        failure = nil; loading = true
        webView.load(URLRequest(url: target, timeoutInterval: 20))
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; failure = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false; failure = error.localizedDescription
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loading = false; failure = L("网页加载失败") }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = allowsWebPreviewNavigation(navigationAction.request.url) || navigationAction.request.url?.absoluteString == "about:blank"
        decisionHandler(allowed && !navigationAction.shouldPerformDownload ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, allowsWebPreviewNavigation(navigationAction.request.url) { webView.load(navigationAction.request) }
        return nil
    }
}

private struct WebPageContent: NSViewRepresentable {
    let page: WebPageState
    func makeNSView(context: Context) -> WKWebView {
        page.webView.navigationDelegate = page; page.webView.uiDelegate = page
        page.load()
        return page.webView
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) {
        view.navigationDelegate = nil; view.uiDelegate = nil
        view.stopLoading(); view.loadHTMLString("", baseURL: nil)
    }
}

import AppKit
import SwiftUI
import LinkPresentation

struct LinkPreview: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> LPLinkView {
        let view = LPLinkView(url: url)
        let provider = LPMetadataProvider()
        provider.timeout = 5
        context.coordinator.provider = provider
        provider.startFetchingMetadata(for: url) { metadata, _ in
            guard let metadata else { return }
            DispatchQueue.main.async { view.metadata = metadata }
        }
        return view
    }
    func updateNSView(_ nsView: LPLinkView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LPLinkView, context: Context) -> CGSize? {
        // Remote metadata must not impose its natural image width on a clipboard card.
        CGSize(width: proposal.width ?? 212, height: proposal.height ?? 180)
    }
    static func dismantleNSView(_ nsView: LPLinkView, coordinator: Coordinator) { coordinator.provider?.cancel() }
    final class Coordinator { var provider: LPMetadataProvider? }
}

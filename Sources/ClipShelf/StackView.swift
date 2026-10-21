import SwiftUI
import ClipboardCore

struct StackView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: ClipboardModel
    let openSettings: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L("顺序粘贴 · %@ 项", model.stackClips.count)).font(.headline)
                Spacer()
                Button { model.stackIDs.reverse() } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }.help(L("反转粘贴顺序")).accessibilityLabel(L("反转粘贴顺序"))
                Button(L("结束"), action: finish)
            }
            Text(L("继续复制以加入队列，在目标应用按 ⌘V 逐项粘贴"))
                .font(.caption).foregroundStyle(.secondary)
            if !model.stackPasteAvailable {
                Button(L("前往设置允许辅助功能，以使用 ⌘V"), action: openSettings).font(.caption)
            }
            if model.stackClips.isEmpty {
                Spacer()
                Image(systemName: "square.stack").font(.system(size: 32)).foregroundStyle(.secondary)
                Text(L("复制文字、图片或文件以加入队列")).font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(model.stackClips.enumerated()), id: \.element.id) { index, clip in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    if clip.kind == .image,
                                       let data = clip.items.flatMap({ $0 }).first(where: { $0.type == "public.png" || $0.type == "public.tiff" })?.data,
                                       let image = NSImage(data: data) {
                                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 90)
                                    } else {
                                        Text(cardClipText(clip)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    Label(clip.sourceName, systemImage: clip.kind.symbol)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Button { model.stackIDs.removeAll { $0 == clip.id } } label: {
                                    Image(systemName: "xmark")
                                }.buttonStyle(.plain).help(L("移出队列")).accessibilityLabel(L("移出队列"))
                            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }.padding(14).frame(width: 320, height: 400)
    }
}

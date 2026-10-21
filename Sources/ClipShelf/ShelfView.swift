import AppKit
import SwiftUI
import ClipboardCore

extension ClipKind {
    var label: String { switch self { case .text: L("文本"); case .link: L("链接"); case .image: L("图片"); case .files: L("文件") } }
    var symbol: String { switch self { case .text: "text.alignleft"; case .link: "link"; case .image: "photo"; case .files: "folder" } }
}

let boardColors: [Color] = [.red, .blue, .orange, .green, .purple, .pink]
private var boardColorNames: [String] { [L("红色"), L("蓝色"), L("橙色"), L("绿色"), L("紫色"), L("粉色")] }

struct ShelfView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: ClipboardModel
    let dismiss: () -> Void
    let openSettings: () -> Void
    let enableCapture: () -> Void
    let paste: ([Clip], Bool) -> Void
    @FocusState private var boardFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var _pendingBoardDelete = State<Pinboard?>(initialValue: nil)
    private var pendingBoardDelete: Pinboard? {
        get { _pendingBoardDelete.wrappedValue }
        nonmutating set { _pendingBoardDelete.wrappedValue = newValue }
    }
    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.20) }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.visible.isEmpty {
                if model.searchPending { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { VStack(spacing: 12) {
                    ShelfIllustration(searching: !model.query.isEmpty).frame(width: 150, height: 94)
                    Text(!model.query.isEmpty ? L("没有找到匹配的内容") : (model.selectedBoardID == nil ? L("留住刚刚复制的灵感") : L("把值得留下的内容，放进这个收藏集")))
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    Text(model.query.isEmpty ? L("复制文字、图片或文件，即可开始收集") : L("试试更短的关键词，或切换内容类型")).font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 16) {
                            ForEach(Array(model.visible.enumerated()), id: \.element.id) { index, clip in
                                ClipCard(clip: clip, quickPasteNumber: model.quickPasteNumber(at: index), selected: model.selection.ids.contains(clip.id),
                                         model: model,
                                         copy: { paste(model.targets(for: clip), false) },
                                         pastePlain: { paste(model.targets(for: clip), true) },
                                         remove: { model.remove(clip) })
                                    .popover(isPresented: Binding(get: { model.previewID == clip.id }, set: { if !$0 && model.previewID == clip.id { model.closePreview() } }), arrowEdge: .bottom) {
                                        ClipPreview(clip: clip, model: model, close: { model.closePreview() })
                                            .background(PreviewPrivacy(visible: model.preferences.showInScreenSharing))
                                    }.id(clip.id)
                            }
                        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24).id("history-start")
                    }.scrollIndicators(.hidden)
                        .onChange(of: model.selectionScrollID) { _, id in if let id { withAnimation(model.searchShown ? nil : motion) {
                            if id == model.visible.first?.id { proxy.scrollTo("history-start", anchor: .leading) }
                            else { proxy.scrollTo(id) }
                        } } }
                        .onChange(of: model.presentationID) { _, _ in proxy.scrollTo("history-start", anchor: .leading) }
                }
            }
        }
        .foregroundStyle(Color.primary).tint(ShelfDesign.accent).background { ShelfGlassBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(LinearGradient(colors: [ShelfDesign.edge, ShelfDesign.line], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .animation(motion, value: model.selectedBoardID)
        .animation(motion, value: model.history.boards)
        .onChange(of: model.query) { _, _ in model.resetSelection() }
        .onChange(of: model.filter) { _, _ in model.resetSelection() }
        .onChange(of: model.creatingBoard) { _, value in if !value { boardFocused = false } }
        .onChange(of: model.editingBoardID) { _, id in if id == nil { boardFocused = false } }
        .alert(L("新建收藏集"), isPresented: $model.namingDroppedBoard) {
            TextField(L("收藏集名称"), text: $model.boardNameDraft)
            Button(L("取消"), role: .cancel) { model.cancelBoardEdit() }
            Button(L("创建")) { model.finishBoardEdit() }.keyboardShortcut(.defaultAction)
                .disabled(model.boardNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text(L("输入名称后，拖来的卡片将自动加入新收藏集。")) }
        .confirmationDialog(L("删除分组？"), isPresented: Binding(get: { pendingBoardDelete != nil }, set: { if !$0 { pendingBoardDelete = nil } })) {
            Button(L("删除分组"), role: .destructive) { if let pendingBoardDelete { model.removeBoard(pendingBoardDelete) }; pendingBoardDelete = nil }
            Button(L("取消"), role: .cancel) { pendingBoardDelete = nil }
        } message: { Text(L("卡片仍会保留在剪贴板历史中。")) }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            search(width: 280)
                Button { model.selectBoard(nil) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.full")
                        Text(L("全部记录"))
                        Text("\(model.history.clips.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 28)
                        .foregroundStyle(model.selectedBoardID == nil ? ShelfDesign.accent : .primary)
                        .background(model.selectedBoardID == nil ? ShelfDesign.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(ShelfHoverStyle()).accessibilityLabel(L("剪贴板")).help(L("全部剪贴板记录"))
                Rectangle().fill(ShelfDesign.line).frame(width: 1, height: 16)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(model.history.boards) { board in
                                if model.editingBoardID == board.id { boardEditor.id(board.id) }
                                else { boardTab(board).id(board.id) }
                            }
                            if model.creatingBoard && !model.namingDroppedBoard { boardEditor.id("new-board") }
                            Button { model.beginBoardEdit() } label: {
                                HStack(spacing: 5) { Image(systemName: "plus"); Text(L("收藏集")) }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 28)
                            }.buttonStyle(ShelfHoverStyle()).foregroundStyle(model.dropTargetNewBoard ? ShelfDesign.accent : .secondary)
                                .background(model.dropTargetNewBoard ? ShelfDesign.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ShelfDesign.accent, lineWidth: model.dropTargetNewBoard ? 2 : 0))
                                .accessibilityLabel(L("创建 Pinboard")).help(L("创建收藏集 (⇧⌘N)，或拖入卡片后命名"))
                                .dropDestination(for: String.self) { items, _ in model.dropToNewBoard(items) } isTargeted: { model.dropTargetNewBoard = $0 }
                        }.padding(.vertical, 3)
                    }.scrollIndicators(.hidden)
                        .onChange(of: model.creatingBoard) { _, value in if value { withAnimation(motion) { proxy.scrollTo("new-board", anchor: .trailing) } } }
                        .onChange(of: model.editingBoardID) { _, id in if let id { withAnimation(motion) { proxy.scrollTo(id) } } }
                        .onChange(of: model.selectedBoardID) { _, id in if let id { withAnimation(motion) { proxy.scrollTo(id) } } }
                }
                Menu {
                    Button(model.paused ? L("继续采集") : L("暂停采集")) { model.paused.toggle() }.disabled(model.demo)
                    Button(L("顺序粘贴")) { model.startStack(); model.resetSelection() }
                    Button(L("设置…"), action: openSettings)
                    Divider()
                    Button(L("创建收藏集…")) { model.beginBoardEdit() }
                    Button(L("退出 ClipShelf")) { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 16)).frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("更多")).id(localization.language)
                if model.demo { Button(L("启用采集"), action: enableCapture).font(.system(size: 11)).buttonStyle(.bordered) }
        }.frame(height: 36)
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 4)
            .overlay(alignment: .bottom) { Rectangle().fill(ShelfDesign.line).frame(height: 1).padding(.horizontal, 24) }
    }
    private func search(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Button {
                if !model.searchShown { model.searchShown = true }
            } label: { Image(systemName: "magnifyingglass").font(.system(size: model.searchShown ? 15 : 20)).foregroundStyle(model.searchShown ? .secondary : .primary).frame(width: 30, height: 30) }
                .buttonStyle(ShelfHoverStyle()).accessibilityLabel(L("搜索")).help(L("搜索 (⌘F)"))
            ShelfSearchField(text: $model.query, submit: { paste(model.selectedClips, false) },
                             register: { model.searchField = $0 },
                             changed: { if !model.searchShown { model.searchShown = true } })
                .frame(height: 22)
            if !model.searchShown {
                Text("⌘ F").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            if model.searchShown {
                if !model.query.isEmpty {
                    Button { model.clearSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel(L("清除搜索"))
                }
                Menu {
                    Button(L("全部类型")) { model.filter = nil }
                    ForEach(ClipKind.allCases, id: \.self) { kind in Button(kind.label) { model.filter = kind } }
                } label: { Image(systemName: "line.3.horizontal.decrease").foregroundStyle(model.filter == nil ? Color.secondary : ShelfDesign.accent) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("筛选")).id(localization.language)
            }
        }
        .padding(.horizontal, 8).frame(width: model.searchShown ? width : 200, height: 32)
        .animation(motion, value: model.searchShown)
        .contentShape(RoundedRectangle(cornerRadius: 9)).onTapGesture { if !model.searchShown { model.searchShown = true } }
        .background(ShelfDesign.paper.opacity(0.60), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(model.searchShown ? ShelfDesign.accent.opacity(0.65) : ShelfDesign.line, lineWidth: 1))
    }
    private var boardEditor: some View {
        HStack(spacing: 6) {
            Circle().fill(boardColors[model.boardColorDraft]).frame(width: 12, height: 12)
            TextField(L("未命名"), text: $model.boardNameDraft).textFieldStyle(.plain).font(.system(size: 14))
                .focused($boardFocused).frame(width: 100).onAppear { DispatchQueue.main.async { boardFocused = true } }
                .onSubmit { model.finishBoardEdit() }.accessibilityLabel(L("分组名称"))
        }.padding(.horizontal, 10).frame(height: 28).background(Color.primary.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(ShelfDesign.accent.opacity(0.55), lineWidth: 3).padding(-3))
    }
    private func boardTab(_ board: Pinboard) -> some View {
        Button { model.selectBoard(board.id) } label: {
            HStack(spacing: 6) {
                Circle().fill(boardColors[board.color]).overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5)).frame(width: 12, height: 12)
                Text(board.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "plus.circle.fill").foregroundStyle(boardColors[board.color]).opacity(model.dropTargetBoardID == board.id ? 1 : 0)
                    .overlay { if model.dropTargetBoardID != board.id { Text("\(board.clipIDs.count)").font(.system(size: 10)).foregroundStyle(.secondary) } }
            }.padding(.horizontal, 10).frame(height: 28)
                .background(model.dropTargetBoardID == board.id ? boardColors[board.color].opacity(0.22) : (model.selectedBoardID == board.id ? Color.primary.opacity(0.09) : .clear), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(boardColors[board.color], lineWidth: model.dropTargetBoardID == board.id ? 2 : 0))
                .shadow(color: boardColors[board.color].opacity(model.dropTargetBoardID == board.id ? 0.25 : 0), radius: 5)
                .animation(motion, value: model.dropTargetBoardID == board.id)
        }.buttonStyle(ShelfHoverStyle()).accessibilityLabel(L("分组：%@", board.name)).help(L("拖入卡片以加入「%@」", board.name))
            .draggable("board:\(board.id.uuidString)")
            .dropDestination(for: String.self) { items, _ in model.drop(items, on: board) } isTargeted: { targeted in
                if targeted { model.dropTargetBoardID = board.id }
                else if model.dropTargetBoardID == board.id { model.dropTargetBoardID = nil }
            }
            .contextMenu {
                Button(L("重命名…")) { model.beginBoardEdit(board) }
                Menu(L("颜色")) {
                    ForEach(0..<boardColors.count, id: \.self) { index in
                        Button { model.recolorBoard(board, color: index) } label: { Label { Text(boardColorNames[index]) } icon: {
                            Image(nsImage: boardColorSwatch(boardColors[index], selected: board.color == index))
                        } }
                    }
                }
                Divider()
                Button(L("删除分组…"), role: .destructive) { pendingBoardDelete = board }
            }
    }
}

private struct ClipCard: View {
    let clip: Clip
    let quickPasteNumber: Int?
    let selected: Bool
    @ObservedObject var model: ClipboardModel
    let copy: () -> Void
    let pastePlain: () -> Void
    let remove: () -> Void
    @FocusState private var renameFocused: Bool
    private var appearance: SourceAppearance { SourceAppearance.forApp(clip.sourceBundle, fallback: clip.kind.symbol) }
    private var image: NSImage? {
        clip.items.flatMap { $0 }.first(where: { $0.type == "public.png" || $0.type == "public.tiff" }).flatMap { NSImage(data: $0.data) }
    }
    private var footerText: String {
        if clip.kind == .text || clip.kind == .link { return L("%@ 个字符", clip.text.count) }
        return Int64(clip.byteCount).formatted(.byteCount(style: .file).locale(Locale(identifier: AppLocalization.shared.language.rawValue)))
    }
    private func relativeTime(_ now: Date) -> String {
        if now.timeIntervalSince(clip.copiedAt) < 60 { return L("刚刚") }
        let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: AppLocalization.shared.language.rawValue); formatter.unitsStyle = .short
        return formatter.localizedString(for: clip.copiedAt, relativeTo: now)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: clip.kind.symbol).foregroundStyle(ShelfDesign.typeColor(clip.kind))
                    if model.renamingID == clip.id {
                        TextField(L("名称"), text: $model.renameDraft).textFieldStyle(.plain).focused($renameFocused)
                            .onSubmit { model.finishRename() }.onAppear { renameFocused = true }
                            .onChange(of: renameFocused) { _, focused in if !focused && model.renamingID == clip.id { model.finishRename() } }
                    } else { Text(clip.title ?? clip.kind.label).lineLimit(1) }
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 60)) { context in Text(relativeTime(context.date)).font(.system(size: 10)).foregroundStyle(.secondary) }
                }.font(.system(size: 11, weight: .medium))
                cardContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack(spacing: 6) {
                    Image(nsImage: appearance.icon).resizable().frame(width: 16, height: 16)
                    Text(clip.sourceName).font(.system(size: 10, weight: .medium)).lineLimit(1).foregroundStyle(.secondary)
                    Circle().fill(Color(nsColor: appearance.color)).frame(width: 5, height: 5)
                    Spacer(minLength: 2)
                    if quickPasteNumber == nil { Text(footerText).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                    else { Color.clear.frame(width: 22, height: 16) }
                }
            }.padding(16).frame(width: 256, height: 268)
                .background {
                    RoundedRectangle(cornerRadius: 14).fill(Color.white)
                        .overlay(alignment: .bottom) {
                            UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                                .fill(Color(nsColor: appearance.color).opacity(0.26)).frame(height: 40)
                                .overlay(alignment: .top) {
                                    Rectangle().fill(Color(nsColor: appearance.color).opacity(0.85)).frame(height: 2)
                                }
                        }
                }
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ShelfDesign.edge, lineWidth: 0.5))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? ShelfDesign.accent : ShelfDesign.line, lineWidth: selected ? 1.5 : 0.75))
                .overlay(alignment: .bottomTrailing) {
                    if let quickPasteNumber {
                        Text(String(quickPasteNumber)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ShelfDesign.accent).frame(width: 22, height: 22)
                            .background(ShelfDesign.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                            .padding(12).allowsHitTesting(false).accessibilityLabel(L("快速粘贴 %@", quickPasteNumber))
                    }
                }
                .shadow(color: .black.opacity(selected ? 0.20 : 0.10), radius: selected ? 10 : 6, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            // A Button consumes mouse tracking before the native drag source can start.
            .onDrag { NSItemProvider(object: model.dragPayload(for: clip) as NSString) } preview: {
                CardDragPreview(clip: clip, count: model.targets(for: clip).count)
            }
            .onTapGesture(count: 2) { if !NSEvent.modifierFlags.contains(.command), !NSEvent.modifierFlags.contains(.shift) { copy() } }
            // Single-click selection must not wait for the double-click recognizer to fail.
            .simultaneousGesture(TapGesture(count: 1).onEnded {
                model.selectClip(clip, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
                NSApp.keyWindow?.makeFirstResponder(nil)
            })
            .accessibilityElement(children: model.renamingID == clip.id ? .contain : .ignore)
            .accessibilityLabel(L("%@，%@，来源 %@", clip.kind.label, clip.text.prefix(40), clip.sourceName))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                model.selectClip(clip, modifiers: [])
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            .accessibilityHint(L("单击选择，Command 点击切换选择，Shift 点击连续选择，双击或按回车复制并收起"))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu { cardMenu }
            .environment(\.colorScheme, .light)
    }
    @ViewBuilder private var cardContent: some View {
        if clip.kind == .link, model.preferences.linkPreviews, let url = safeLinkURL(clip) {
            LinkPreview(url: url).allowsHitTesting(false).clipShape(RoundedRectangle(cornerRadius: 8))
        } else if clip.kind == .files {
            VStack(alignment: .leading, spacing: 6) {
                FileCardThumbnail(urls: filePreviewURLs(clip), refreshID: model.presentationID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                Text(clip.text).font(.system(size: 11)).lineLimit(2).foregroundStyle(.secondary)
            }
        } else if let image {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ShelfDesign.canvas, in: RoundedRectangle(cornerRadius: 8))
        } else {
            Text(cardClipText(clip)).font(.system(size: 14)).lineSpacing(4).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        }
    }
    @ViewBuilder private var cardMenu: some View {

                if clip.kind == .files, let url = previewFileURL(clip) {
                    Button(L("使用 %@ 打开", NSWorkspace.shared.urlForApplication(toOpen: url).map { (FileManager.default.displayName(atPath: $0.path) as NSString).deletingPathExtension } ?? L("默认应用"))) { NSWorkspace.shared.open(url) }
                    Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting(filePreviewURLs(clip)) }
                    Divider()
                } else if clip.kind == .link, let url = safeLinkURL(clip) {
                    Button(L("打开链接")) { NSWorkspace.shared.open(url) }
                    Divider()
                }
                Button(L("粘贴到 %@", model.pasteTargetName), action: copy).keyboardShortcut(.return, modifiers: [])
                Button(L("以纯文本粘贴"), action: pastePlain).keyboardShortcut(.return, modifiers: .shift)
                Button(L("复制")) { model.copy(model.targets(for: clip)) }.keyboardShortcut("c")
                Divider()
                if [.text, .link].contains(clip.kind) { Button(L("编辑")) { model.beginTextEdit(clip) }.keyboardShortcut("e") }
                if clip.kind == .image { Button(L("编辑")) { model.beginImageEdit(clip) }.keyboardShortcut("e") }
                Button(L("重命名")) { model.beginRename(clip) }.keyboardShortcut("r")
                Button(L("删除"), role: .destructive, action: remove).keyboardShortcut(.delete, modifiers: [])
                Divider()
                Menu(L("固定")) {
                    ForEach(model.history.boards) { board in
                        Button { model.add(clip, to: board) } label: { Label { Text(board.name) } icon: { Image(nsImage: pinboardMenuIcon(color: board.color, pinned: board.clipIDs.contains(clip.id))) } }
                    }
                    Divider()
                    Button(L("新建收藏集…")) { model.beginBoardEdit(clip: clip) }
                }
                if model.selectedBoardID != nil { Button(L("取消固定")) { model.removeFromCurrentBoard(clip) } }
                Divider()
                Button(L("预览")) { model.previewID = clip.id }.keyboardShortcut(.space, modifiers: [])
                Menu(L("分享")) {
                    let items = sharingItems(model.targets(for: clip))
                    ForEach(Array(NSSharingService.sharingServices(forItems: items).enumerated()), id: \.offset) { _, service in
                        Button(service.title) { service.perform(withItems: items) }
                    }
                }

    }

}

struct ShelfHoverStyle: ButtonStyle {
    var lift = false
    func makeBody(configuration: Configuration) -> some View { HoverLabel(configuration: configuration, lift: lift) }
    private struct HoverLabel: View {
        let configuration: ButtonStyleConfiguration
        let lift: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        private var _hovered = State(initialValue: false)
        private var hovered: Bool { get { _hovered.wrappedValue } nonmutating set { _hovered.wrappedValue = newValue } }
        var body: some View {
            configuration.label.background(Color.primary.opacity(configuration.isPressed ? 0.10 : (hovered ? 0.05 : 0)), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8)).onHover { hovered = $0 }
                .offset(y: lift && hovered && !reduceMotion ? -2 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        }
    }
}

@MainActor func pinboardMenuIcon(color: Int, pinned: Bool) -> NSImage {
    let colors: [NSColor] = [.systemRed, .systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink]
    let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
        colors[min(max(color, 0), colors.count - 1)].setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        if pinned {
            let path = NSBezierPath(); path.move(to: NSPoint(x: 4, y: 7)); path.line(to: NSPoint(x: 6, y: 5)); path.line(to: NSPoint(x: 10, y: 9))
            NSColor.white.setStroke(); path.lineWidth = 1.5; path.stroke()
        }
        return true
    }
    image.isTemplate = false
    return image
}

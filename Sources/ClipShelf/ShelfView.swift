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
    private var _sourceDetailsShown = State(initialValue: false)
    private var sourceDetailsShown: Bool {
        get { _sourceDetailsShown.wrappedValue }
        nonmutating set { _sourceDetailsShown.wrappedValue = newValue }
    }
    private var _filtersShown = State(initialValue: false)
    private var filtersShown: Bool {
        get { _filtersShown.wrappedValue }
        nonmutating set { _filtersShown.wrappedValue = newValue }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var _pendingBoardDelete = State<Pinboard?>(initialValue: nil)
    private var pendingBoardDelete: Pinboard? {
        get { _pendingBoardDelete.wrappedValue }
        nonmutating set { _pendingBoardDelete.wrappedValue = newValue }
    }
    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.20) }
    var body: some View {
        let clips = model.visible
        VStack(spacing: 0) {
            toolbar.zIndex(1)
            if clips.isEmpty {
                if model.searchPending { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { VStack(spacing: 12) {
                    ShelfIllustration(searching: model.searchActive).frame(width: 150, height: 94)
                    Text(model.searchActive ? L("没有找到匹配的内容") : (model.selectedBoardID == nil ? L("留住刚刚复制的灵感") : L("把值得留下的内容，放进这个收藏集")))
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    Text(!model.searchActive ? L("复制文字、图片或文件，即可开始收集") : L("试试更短的关键词，或切换内容类型")).font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 16) {
                            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                                ClipCard(clip: clip, quickPasteNumber: model.quickPasteNumber(at: index), selected: model.selection.ids.contains(clip.id),
                                         model: model, language: localization.language,
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
        .animation(motion, value: model.selectedBoardID)
        .animation(motion, value: model.history.boards)
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
            search(width: 360)
                Button { model.selectBoard(nil) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.full")
                        Text(L("全部记录"))
                        Text("\(model.history.clips.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 28)
                        .foregroundStyle(model.selectedBoardID == nil ? ShelfDesign.accent : .primary)
                        .background(model.selectedBoardID == nil ? ShelfDesign.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(ShelfHoverStyle()).accessibilityLabel(L("剪贴板")).help(L("全部剪贴板记录"))
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
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 2)
    }
    private func search(width: CGFloat) -> some View {
        SearchInputRegion(input: model.searchInput) {
        HStack(spacing: 6) {
            Button {
                if !model.searchShown { model.searchShown = true }
            } label: { Image(systemName: "magnifyingglass").font(.system(size: model.searchShown ? 15 : 20)).foregroundStyle(model.searchShown ? .secondary : .primary).frame(width: 30, height: 30) }
                .buttonStyle(ShelfHoverStyle()).accessibilityLabel(L("搜索")).help(L("搜索 (⌘F)"))
            if !model.selectedSourceApps.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        ForEach(model.selectedSourceApps) { app in
                            Button { model.toggleSourceApp(app) } label: {
                                HStack(spacing: 4) {
                                    sourceIcon(app)
                                    Text(app.name).lineLimit(1)
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                                }.font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 4)
                                    .background(ShelfDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).help(L("移除来源筛选：%@", app.name))
                                .accessibilityLabel(L("移除来源筛选：%@", app.name))
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                    Button { sourceDetailsShown.toggle() } label: {
                        HStack(spacing: 4) {
                            Text("\(model.selectedSourceApps.count)").monospacedDigit()
                        }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4)
                            .background(ShelfDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(L("已选 %@ 个来源应用", model.selectedSourceApps.count))
                        .help(model.selectedSourceApps.map(\.name).joined(separator: "\n"))
                        .popover(isPresented: _sourceDetailsShown.projectedValue, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 12) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(model.selectedSourceApps) { app in
                                            Button {
                                                model.toggleSourceApp(app)
                                                if model.selectedSourceIDs.isEmpty { sourceDetailsShown = false }
                                            } label: {
                                                HStack(spacing: 10) {
                                                    sourceIcon(app)
                                                        .frame(width: 28, height: 28)
                                                        .background(ShelfDesign.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                                                    Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                                    Spacer()
                                                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                                                }.padding(8).contentShape(RoundedRectangle(cornerRadius: 10))
                                                    .background(ShelfDesign.card.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                                            }.buttonStyle(ShelfHoverStyle()).accessibilityLabel(L("移除来源筛选：%@", app.name))
                                        }
                                    }
                                }.scrollIndicators(.hidden).frame(height: min(max(CGFloat(model.selectedSourceApps.count) * 48 - 4, 0), 284))
                            }.padding(14).frame(width: 260)
                                .background(ShelfDesign.paper.opacity(0.85))
                        }
                }.frame(width: sourceTokensWidth, alignment: .leading)
            }
            ShelfSearchField(text: $model.query, submit: model.submitSearch,
                             register: { model.searchField = $0 },
                             changed: { if !model.searchShown { model.searchShown = true } },
                             focusChanged: { if model.searchFocused != $0 { model.searchFocused = $0 } }, moveSuggestion: model.moveSourceSuggestion)
                .frame(height: 22)
            if !model.searchShown {
                Text("⌘ F").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            if model.searchShown {
                if model.searchActive {
                    Button { model.clearSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel(L("清除搜索"))
                }
                Button { filtersShown.toggle() } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(model.filter == nil && model.selectedSourceIDs.isEmpty ? Color.secondary : ShelfDesign.accent)
                        .frame(width: 22, height: 22)
                }.buttonStyle(ShelfHoverStyle()).accessibilityLabel(L("筛选"))
                    .popover(isPresented: _filtersShown.projectedValue, arrowEdge: .bottom) {
                        ShelfFilterPanel(model: model).id(localization.language)
                    }
            }
        }
        .padding(.horizontal, 8).frame(width: model.searchShown ? width : 200, height: 32)
        .animation(motion, value: model.searchShown)
        .contentShape(RoundedRectangle(cornerRadius: 9)).onTapGesture { if !model.searchShown { model.searchShown = true } }
        .background(ShelfDesign.paper.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ShelfDesign.accent.opacity(model.searchFocused ? 0.24 : 0), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.035), radius: 3, y: 1)
        .overlay(alignment: .topLeading) {
            if model.searchShown && !model.suggestedSourceApps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.suggestedSourceApps.enumerated()), id: \.element.id) { index, app in
                        Button { model.selectSourceSuggestion(app) } label: {
                            HStack(spacing: 10) {
                                sourceIcon(app)
                                    .frame(width: 28, height: 28)
                                    .background(ShelfDesign.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Spacer()
                                Image(systemName: "return").font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary).opacity(model.sourceSuggestionIndex == index ? 1 : 0)
                            }.padding(8).contentShape(RoundedRectangle(cornerRadius: 10))
                                .background(model.sourceSuggestionIndex == index ? ShelfDesign.accent.opacity(0.10) : ShelfDesign.card.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(ShelfHoverStyle()).accessibilityLabel(L("筛选来源：%@", app.name))
                    }
                }.padding(8).frame(width: width)
                    .background(ShelfDesign.paper.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.10), radius: 16, y: 7).offset(y: 40)
            }
        }
        }
    }
    private func sourceIcon(_ app: SourceApplication) -> some View {
        Image(nsImage: SourceAppearance.forApp(app.bundle, fallback: "app").icon).resizable().frame(width: 14, height: 14)
    }
    private var sourceTokensWidth: CGFloat {
        let apps = model.selectedSourceApps
        let font = NSFont.systemFont(ofSize: 11)
        var width: CGFloat = 0
        for app in apps {
            if width > 0 { width += 4 }
            width += ceil((app.name as NSString).size(withAttributes: [.font: font]).width) + 44
            if width > 140 {
                let count = "\(apps.count)" as NSString
                return max(24, ceil(count.size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]).width) + 14)
            }
        }
        return width
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

private struct ShelfFilterPanel: View {
    @ObservedObject var model: ClipboardModel
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                typeButton(nil)
                ForEach(ClipKind.allCases, id: \.self) { typeButton($0) }
            }
            ScrollView {
                VStack(spacing: 4) {
                    Button { model.selectedSourceIDs = [] } label: {
                        HStack {
                            Text(L("全部应用")).font(.system(size: 11, weight: .medium))
                            Spacer()
                            if model.selectedSourceIDs.isEmpty { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                        }.foregroundStyle(.secondary).padding(10).contentShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(ShelfHoverStyle())
                    ForEach(model.sourceApps) { app in
                        let selected = model.selectedSourceIDs.contains(app.id)
                        Button { model.toggleSourceApp(app) } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: SourceAppearance.forApp(app.bundle, fallback: "app").icon)
                                    .resizable().frame(width: 18, height: 18).frame(width: 28, height: 28)
                                    .background(ShelfDesign.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 14)).foregroundStyle(selected ? ShelfDesign.accent : Color.secondary.opacity(0.3))
                            }.padding(8).contentShape(RoundedRectangle(cornerRadius: 10))
                                .background(selected ? ShelfDesign.accent.opacity(0.09) : ShelfDesign.card.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(ShelfHoverStyle()).help(app.name)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }.scrollIndicators(.hidden).frame(height: min(CGFloat(model.sourceApps.count) * 48 + 36, 300))
        }.padding(12).frame(width: 280).background(ShelfDesign.paper.opacity(0.85))
    }
    private func typeButton(_ kind: ClipKind?) -> some View {
        let selected = model.filter == kind
        return Button { model.filter = kind } label: {
            VStack(spacing: 5) {
                Image(systemName: kind?.symbol ?? "square.grid.2x2").font(.system(size: 13))
                Text(kind?.label ?? L("全部类型")).font(.system(size: 10)).lineLimit(1)
            }.frame(maxWidth: .infinity).frame(height: 46)
                .foregroundStyle(selected ? ShelfDesign.accent : Color.secondary)
                .background(selected ? ShelfDesign.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(ShelfHoverStyle()).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SearchInputRegion<Content: View>: View {
    @ObservedObject var input: SearchInput
    @ViewBuilder let content: () -> Content
    var body: some View {
        let _ = input.text
        content()
    }
}

private struct ClipCard: View {
    let clip: Clip
    let quickPasteNumber: Int?
    let selected: Bool
    @ObservedObject var model: ClipboardModel
    let language: AppLanguage
    let copy: () -> Void
    let pastePlain: () -> Void
    let remove: () -> Void
    @FocusState private var renameFocused: Bool
    private var appearance: SourceAppearance { SourceAppearance.forApp(clip.sourceBundle, fallback: clip.kind.symbol) }
    private func relativeTime(_ now: Date) -> String {
        if now.timeIntervalSince(clip.copiedAt) < 60 { return L("刚刚") }
        let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: AppLocalization.shared.language.rawValue); formatter.unitsStyle = .short
        return formatter.localizedString(for: clip.copiedAt, relativeTo: now)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                if model.renamingID == clip.id {
                        TextField(L("名称"), text: $model.renameDraft).textFieldStyle(.plain).focused($renameFocused)
                            .onSubmit { model.finishRename() }.onAppear { renameFocused = true }
                            .onChange(of: renameFocused) { _, focused in if !focused && model.renamingID == clip.id { model.finishRename() } }
                } else if let title = clip.title {
                    Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                ClipCardContent(clip: clip, linkPreviews: model.preferences.linkPreviews, refreshID: model.presentationID)
                    .equatable().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ClipCardFooter(clip: clip, quickPasteNumber: quickPasteNumber, language: language).equatable()
                    .offset(y: 4)
            }.padding(16).frame(width: 256, height: 268)
                .background {
                    RoundedRectangle(cornerRadius: 16).fill(ShelfDesign.card)
                        .overlay {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0.55),
                                .init(color: Color(nsColor: appearance.color).opacity(0.035), location: 0.78),
                                .init(color: Color(nsColor: appearance.color).opacity(0.13), location: 1)
                            ], startPoint: .top, endPoint: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                }
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ShelfDesign.accent.opacity(selected ? 0.55 : 0), lineWidth: 1.25))
                .overlay(alignment: .topTrailing) {
                    if model.commandHeld {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(relativeTime(context.date)).font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                                .background(ShelfDesign.paper, in: RoundedRectangle(cornerRadius: 7))
                        }.padding(8).allowsHitTesting(false)
                    }
                }
                .shadow(color: .black.opacity(selected ? 0.12 : 0.065), radius: selected ? 12 : 8, y: selected ? 5 : 3)
            .contentShape(RoundedRectangle(cornerRadius: 16))
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

private struct ClipCardContent: View, Equatable {
    let clip: Clip
    let linkPreviews: Bool
    let refreshID: UUID
    private var image: NSImage? {
        clip.items.flatMap { $0 }.first(where: { $0.type == "public.png" || $0.type == "public.tiff" }).flatMap { NSImage(data: $0.data) }
    }
    var body: some View {
        if clip.kind == .link, linkPreviews, let url = safeLinkURL(clip) {
            LinkPreview(url: url).allowsHitTesting(false).clipShape(RoundedRectangle(cornerRadius: 8))
        } else if clip.kind == .files {
            VStack(alignment: .leading, spacing: 6) {
                FileCardThumbnail(urls: filePreviewURLs(clip), refreshID: refreshID)
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
}

private struct ClipCardFooter: View, Equatable {
    let clip: Clip
    let quickPasteNumber: Int?
    let language: AppLanguage
    var body: some View {
        let appearance = SourceAppearance.forApp(clip.sourceBundle, fallback: clip.kind.symbol)
        HStack(spacing: 6) {
            Image(nsImage: appearance.icon).resizable().frame(width: 16, height: 16)
            Text(clip.sourceName).font(.system(size: 10, weight: .medium)).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            ZStack(alignment: .trailing) {
                Text(clip.kind == .text || clip.kind == .link ? L("%@ 个字符", clip.text.count) : Int64(clip.byteCount).formatted(.byteCount(style: .file).locale(Locale(identifier: language.rawValue))))
                    .opacity(quickPasteNumber == nil ? 1 : 0)
                    .accessibilityHidden(quickPasteNumber != nil)
                if let quickPasteNumber {
                    Text(String(quickPasteNumber)).accessibilityLabel(L("快速粘贴 %@", quickPasteNumber))
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: clip.kind.symbol)
                .font(.system(size: 11)).foregroundStyle(ShelfDesign.typeColor(clip.kind))
                .accessibilityLabel(clip.kind.label)
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

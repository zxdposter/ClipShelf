import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import ApplicationServices

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "通用", intelligence = "智能", privacy = "隐私", shortcuts = "键盘快捷键"
    var id: Self { self }
    var symbol: String { switch self { case .general: "gearshape"; case .intelligence: "sparkles"; case .privacy: "hand.raised"; case .shortcuts: "keyboard" } }
}

@MainActor
private final class SettingsState: ObservableObject {
    @Published var page = SettingsPage.general
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    @Published var loginBusy = false
    @Published var error: String?
    @Published var clearRequested = false
    @Published var resetRequested = false
    @Published var selectedExcluded: String?
    @Published var helpShown = false
    func setLogin(_ enabled: Bool) {
        loginBusy = true
        Task {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                loginEnabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
                error = nil
            } catch { self.error = L("开机启动设置失败：%@", error.localizedDescription) }
            loginBusy = false
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: ClipboardModel
    @ObservedObject var preferences: Preferences
    let changeShortcut: (ShortcutAction, KeyBinding?) -> Void
    let recordingChanged: (Bool) -> Void
    let enableCapture: () -> Void
    @StateObject private var state = SettingsState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var excluded: [String] { Array(NSOrderedSet(array: preferences.excludedApps.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })) as? [String] ?? [] }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ShelfMark()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ClipShelf").font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text(L("留住片刻，随手找回")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(.bottom, 28)
                ForEach(SettingsPage.allCases) { page in
                    Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { state.page = page } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.symbol).frame(width: 20)
                            Text(L(page.rawValue))
                            Spacer()
                            if state.page == page { Circle().fill(ShelfDesign.accent).frame(width: 5, height: 5) }
                        }.font(.system(size: 13, weight: state.page == page ? .semibold : .regular))
                            .padding(.horizontal, 12).frame(height: 42)
                            .foregroundStyle(state.page == page ? ShelfDesign.accent : .secondary)
                            .background(state.page == page ? ShelfDesign.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(ShelfHoverStyle()).accessibilityLabel(L(page.rawValue))
                }
                Spacer()
                ShelfIllustration().frame(height: 110).padding(.horizontal, 12)
                Label(L("本地保存 · 由你掌控"), systemImage: "internaldrive").font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 12)
                if model.demo { Button(L("启用真实采集"), action: enableCapture).font(.system(size: 11)).padding(.bottom, 8) }
                Button { state.helpShown = true } label: { Label(L("使用帮助"), systemImage: "questionmark.circle").font(.system(size: 12)) }.buttonStyle(.plain)
            }.padding(.horizontal, 20).padding(.top, 60).padding(.bottom, 24).frame(width: 220).background(ShelfDesign.canvas)
            Rectangle().fill(ShelfDesign.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L(state.page.rawValue)).font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text(pageDescription).font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.horizontal, 30).padding(.top, 54).padding(.bottom, 24)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch state.page {
                        case .general: general
                        case .intelligence: intelligence
                        case .privacy: privacy
                        case .shortcuts: shortcuts
                        }
                        if let error = state.error { Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled) }
                    }.padding(.horizontal, 30).padding(.bottom, 30)
                }.scrollIndicators(.hidden).disabled(model.demo).id(state.page).transition(.opacity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(ShelfDesign.canvas.opacity(0.45))
        }.frame(width: 820, height: 650).background(ShelfDesign.paper).tint(ShelfDesign.accent).ignoresSafeArea(.container, edges: .top)
            .confirmationDialog(L("删除历史记录？"), isPresented: $state.clearRequested) {
                Button(L("删除未收藏历史"), role: .destructive) { model.clearUnpinned() }
                Button(L("取消"), role: .cancel) {}
            } message: { Text(L("此操作无法撤销，Pinboard 中的卡片会保留。")) }
            .confirmationDialog(L("将快捷方式重置为默认？"), isPresented: $state.resetRequested) {
                Button(L("重置")) {
                    for action in ShortcutAction.allCases { changeShortcut(action, action.defaultBinding) }
                    preferences.quickPasteModifier = .command; preferences.plainTextModifier = .shift
                }
                Button(L("取消"), role: .cancel) {}
            }
            .alert(L("ClipShelf 使用帮助"), isPresented: $state.helpShown) {
                Button(L("好"), role: .cancel) {}
            } message: {
                Text(L("使用设定的快捷键唤醒；单击选择，⌘点击增减选择，Shift 连选，⌘A 全选。回车或双击粘贴。⌘F 搜索，Esc 退出搜索或收起。拖动卡片到 Pinboard 收藏。智能页的 MCP 仅通过本机 stdio 连接，每次会话需要批准。"))
            }
    }

    private var pageDescription: String {
        switch state.page {
        case .general: L("让复制、收藏和粘贴，符合你的工作习惯。")
        case .intelligence: L("连接工具，让保存的内容发挥更多作用。")
        case .privacy: L("决定哪些内容值得保存，哪些应当跳过。")
        case .shortcuts: L("少一点切换，让常用操作留在指尖。")
        }
    }

    private func group<Content: View>(verticalPadding: CGFloat = 8, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content).padding(.horizontal, 16).padding(.vertical, verticalPadding)
            .background(ShelfDesign.paper, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ShelfDesign.line, lineWidth: 1))
    }
    private func toggle(_ title: String, subtitle: String? = nil, value: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 5)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(title)
        }.padding(.vertical, subtitle == nil ? 10 : 9)
    }
    private func heading(_ title: String) -> some View { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 2).padding(.top, 2) }

    private var general: some View {
        Group {
            group {
                HStack {
                    Text(L("语言")).font(.system(size: 13))
                    Spacer()
                    Picker(L("语言"), selection: $preferences.language) {
                        ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
                    }.labelsHidden().pickerStyle(.menu).frame(width: 120)
                }.padding(.vertical, 9)
                Divider()
                HStack {
                    Text(L("外观")).font(.system(size: 13))
                    Spacer()
                    Picker(L("外观"), selection: $preferences.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in Text(appearance.title).tag(appearance) }
                    }.labelsHidden().pickerStyle(.menu).frame(width: 120)
                }.padding(.vertical, 9)
                Divider()
                toggle(L("登录时打开"), value: Binding(get: { state.loginEnabled }, set: state.setLogin)).disabled(state.loginBusy)
                if SMAppService.mainApp.status == .requiresApproval { Button(L("前往系统设置批准")) { SMAppService.openSystemSettingsLoginItems() }.font(.system(size: 11)).padding(.bottom, 8) }
                Divider()
                toggle(L("音效"), value: $preferences.soundEnabled)
            }
            VStack(alignment: .leading, spacing: 10) {
                heading(L("粘贴方式"))
                group {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 14) {
                            radio(L("到当前活动应用"), subtitle: L("将选定的项目直接粘贴到您当前正在使用的应用程序中。"), target: .activeApplication)
                            radio(L("到剪贴板"), subtitle: L("将选定的项目复制到系统剪贴板，以便稍后手动粘贴。"), target: .clipboard)
                        }
                        ShelfIllustration().frame(width: 120, height: 82).padding(.top, 3)
                    }.padding(.vertical, 8)
                    if preferences.pasteDestination == .activeApplication && !AXIsProcessTrusted() {
                        Button(L("允许直接粘贴…")) {
                            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                        }.font(.system(size: 11)).padding(.bottom, 8)
                    }
                    Divider()
                    Toggle(L("始终以纯文本粘贴"), isOn: $preferences.alwaysPlainText).toggleStyle(.checkbox).font(.system(size: 13)).padding(.vertical, 9)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                heading(L("历史保留"))
                group {
                    retentionPicker.padding(.vertical, 10)
                    Text(L("仅清理未收藏内容，收藏集中的卡片会保留。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 12)
                    Divider()
                    HStack { Spacer(); Button(L("删除历史…")) { state.clearRequested = true }.buttonStyle(.bordered) }.padding(.vertical, 8)
                }
            }
        }
    }
    private func radio(_ title: String, subtitle: String, target: PasteDestination) -> some View {
        Button { preferences.pasteDestination = target } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: preferences.pasteDestination == target ? "largecircle.fill.circle" : "circle.fill")
                    .font(.system(size: 16)).foregroundStyle(preferences.pasteDestination == target ? ShelfDesign.accent : .gray.opacity(0.25))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(preferences.pasteDestination == target ? .isSelected : [])
    }
    private var intelligence: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(L("MCP 与 AI 工具"))
            group {
                toggle(L("启用 MCP"), subtitle: L("允许 AI 应用连接到 ClipShelf。只有经你批准的应用才能访问你的剪贴板内容和收藏集。"), value: $preferences.mcpEnabled)
                if preferences.mcpEnabled {
                    Divider()
                    HStack { Text(L("每个客户端会话均需批准")).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button(L("复制连接配置"), action: copyMCPConfiguration) }.padding(.vertical, 10)
                }
            }
        }
    }
    private var privacy: some View {
        Group {
            group {
                toggle(L("在屏幕共享期间显示"), subtitle: L("允许在共享屏幕时向其他人显示 ClipShelf。"), value: $preferences.showInScreenSharing)
                    .help(L("关闭后使用 macOS 窗口共享保护；现代屏幕录制工具是否遵循该设置由系统决定。"))
                Divider()
                toggle(L("生成链接预览"), subtitle: L("可能会影响一次性和敏感链接，预览会访问目标网站。"), value: $preferences.linkPreviews)
            }
            group {
                toggle(L("忽略机密内容"), subtitle: L("在检测到时不保存密码和敏感数据。"), value: $preferences.ignoreConfidential)
                Divider()
                toggle(L("忽略瞬时内容"), subtitle: L("不要保存其他应用程序生成的临时数据。"), value: $preferences.ignoreTransient)
            }
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) { heading(L("忽略应用程序")); Text(L("不要保存从以下应用程序复制的内容。")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 10) }
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(excluded, id: \.self) { bundle in
                                Button { state.selectedExcluded = bundle } label: {
                                    HStack(spacing: 10) {
                                        Image(nsImage: excludedIcon(bundle)).resizable().frame(width: 26, height: 26)
                                        Text(excludedName(bundle)).font(.system(size: 13)); Spacer()
                                    }.padding(.horizontal, 9).frame(height: 40).contentShape(Rectangle())
                                        .foregroundStyle(state.selectedExcluded == bundle ? Color.white : .primary)
                                        .background(state.selectedExcluded == bundle ? ShelfDesign.accent : .clear)
                                }.buttonStyle(.plain).accessibilityLabel(excludedName(bundle))
                                if bundle != excluded.last { Divider().padding(.leading, 46) }
                            }
                        }
                    }.frame(height: min(160, max(80, CGFloat(excluded.count) * 40))).scrollIndicators(.hidden)
                    HStack(spacing: 0) {
                        Button(action: chooseExcludedApp) { Image(systemName: "plus").frame(width: 23, height: 24) }.accessibilityLabel(L("添加忽略应用"))
                        Divider().frame(height: 15)
                        Button {
                            preferences.excludedApps = excluded.filter { $0 != state.selectedExcluded }.joined(separator: "\n"); state.selectedExcluded = nil
                        } label: { Image(systemName: "minus").frame(width: 23, height: 24) }.disabled(state.selectedExcluded == nil).accessibilityLabel(L("移除忽略应用"))
                        Spacer()
                    }.buttonStyle(.plain).foregroundStyle(.secondary).background(Color.primary.opacity(0.035))
                }.background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    private var shortcuts: some View {
        Group {
            group(verticalPadding: 0) { shortcutRow(.activate); Divider(); shortcutRow(.stack) }
            group(verticalPadding: 0) { shortcutRow(.nextBoard); Divider(); shortcutRow(.previousBoard) }
            group(verticalPadding: 0) {
                HStack {
                    Text(L("快速粘贴")).font(.system(size: 13)); Spacer()
                    modifierMenu(L("快速粘贴"), selection: $preferences.quickPasteModifier)
                    Text("+ 1...9").font(.system(size: 13))
                }.padding(.vertical, 8)
                Divider()
                HStack {
                    Text(L("纯文本模式")).font(.system(size: 13)); Spacer()
                    modifierMenu(L("纯文本模式"), selection: $preferences.plainTextModifier)
                }.padding(.vertical, 8)
            }
            HStack { Spacer(); Button(L("将快捷方式重置为默认…")) { state.resetRequested = true }.buttonStyle(.bordered) }
        }
    }
    private func modifierMenu(_ title: String, selection: Binding<KeyModifier>) -> some View {
        ModifierPicker(selection: selection, label: title).frame(width: 132, height: 26)
    }
    private var retentionPicker: some View {
        HStack(spacing: 6) {
            ForEach(RetentionPeriod.allCases) { period in
                Button { model.setRetention(period) } label: {
                    Text(period == .forever ? L("不限") : L("1%@", period.title))
                        .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(preferences.retention == period ? ShelfDesign.accent : .secondary)
                        .background(preferences.retention == period ? ShelfDesign.accent.opacity(0.10) : ShelfDesign.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(preferences.retention == period ? ShelfDesign.accent.opacity(0.4) : .clear, lineWidth: 1))
                }.buttonStyle(.plain).accessibilityLabel(period == .forever ? L("永久保留") : L("保留1%@", period.title))
                    .accessibilityAddTraits(preferences.retention == period ? .isSelected : [])
            }
        }.help(L("200 条和 50 MB 的容量上限仍然适用。"))
    }
    private func shortcutRow(_ action: ShortcutAction) -> some View {
        HStack {
            Text(action.title).font(.system(size: 13)); Spacer()
            HStack(spacing: 0) {
                ShortcutRecorder(binding: preferences.binding(for: action), global: action.isGlobal, change: { changeShortcut(action, $0) }, recordingChanged: recordingChanged).frame(width: 98, height: 24)
                Button { changeShortcut(action, nil) } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 20, height: 24) }
                    .buttonStyle(.plain).disabled(preferences.binding(for: action) == nil).accessibilityLabel(L("删除%@快捷键", action.title))
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.gray.opacity(0.2), lineWidth: 0.75))
        }.padding(.vertical, 3).frame(height: 36)
    }
    private func excludedIcon(_ bundle: String) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }
    private func excludedName(_ bundle: String) -> String {
        if bundle == "com.apple.Passwords" { return L("密码") }
        if bundle == "com.apple.keychainaccess" { return L("钥匙串访问") }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { FileManager.default.displayName(atPath: $0.path) } ?? bundle
    }
    private func chooseExcludedApp() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.application]; picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false; picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.begin { response in
            guard response == .OK, let url = picker.url, let bundle = Bundle(url: url)?.bundleIdentifier else { return }
            if !preferences.excludes(bundle) { preferences.excludedApps = (excluded + [bundle]).joined(separator: "\n") }
        }
    }
    private func copyMCPConfiguration() {
        guard let executable = Bundle.main.executableURL?.path,
              let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": ["ClipShelf": ["command": executable, "args": ["--mcp"]]]], options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string)
    }
}

private struct ModifierPicker: NSViewRepresentable {
    @Binding var selection: KeyModifier
    let label: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false; button.font = .systemFont(ofSize: 13)
        button.addItems(withTitles: KeyModifier.allCases.map(\.title))
        button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:))
        button.setAccessibilityLabel(label)
        return button
    }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        context.coordinator.change = { selection = $0 }
        view.selectItem(at: KeyModifier.allCases.firstIndex(of: selection) ?? 0)
    }
    final class Coordinator: NSObject {
        var change: ((KeyModifier) -> Void)?
        @objc func changed(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard KeyModifier.allCases.indices.contains(index) else { return }
            change?(KeyModifier.allCases[index])
        }
    }
}

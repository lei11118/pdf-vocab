import SwiftUI

/// 设置页(v0.6.9 引入):先放「查词」开关,后续里程碑(Pencil 动作映射、OCR 引擎选择等)继续往里加。
/// 入口:文档库 ⚙️ 与阅读页 ⚙️。
struct SettingsView: View {
    /// v0.12.0(M7):数据备份/恢复需要数据库连接
    let db: AppDatabase

    @AppStorage("autoSpeakOnSelect") private var autoSpeakOnSelect = false
    @AppStorage("autoCollectOnSelect") private var autoCollectOnSelect = false
    @AppStorage("autoHighlightCollected") private var autoHighlightCollected = false
    @AppStorage("pencilHoverPreview") private var pencilHoverPreview = true
    @AppStorage("pencilHaptics") private var pencilHaptics = true
    @AppStorage("pencilAutoReturnEraser") private var pencilAutoReturnEraser = true
    /// v0.18.0:书写贴边自动滚动 + Pencil 手势映射
    @AppStorage("writingAutoScroll") private var writingAutoScroll = true
    @AppStorage("pencilLineSnap") private var pencilLineSnap = true
    @AppStorage("pencilDoubleTapAction") private var pencilDoubleTapAction = "eraser"
    @AppStorage("pencilSqueezeAction") private var pencilSqueezeAction = "arc"
    @Environment(\.dismiss) private var dismiss

    private enum BackupState { case idle, exporting, importing }
    @State private var backupState: BackupState = .idle
    @State private var shareFile: ShareFileItem?
    @State private var showRestorePicker = false
    @State private var pendingRestoreURL: URL?
    @State private var showConfirmRestore = false
    @State private var restoreMessage: String?
    @State private var showStarDictPicker = false
    @State private var dictImporting = false
    @State private var userDictName: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("选词后自动发音", isOn: $autoSpeakOnSelect)
                } header: {
                    Text("查词")
                } footer: {
                    Text("开启后:选中单词、词卡出现时自动朗读一次(美音)。")
                }
                Section {
                    Toggle("选中即自动收录并永久加亮", isOn: $autoCollectOnSelect)
                    Toggle("已收录词自动加亮(打开页面时扫描)", isOn: $autoHighlightCollected)
                } header: {
                    Text("生词本")
                } footer: {
                    Text("开启后:选中的单词立即加入生词本并在页面上永久加亮,无需再点「加入生词本」。")
                }
                Section {
                    Toggle("Pencil 悬停预览", isOn: $pencilHoverPreview)
                    Toggle("触觉反馈", isOn: $pencilHaptics)
                    Toggle("橡皮擦完自动回到上一支笔", isOn: $pencilAutoReturnEraser)
                    Toggle("书写时贴边自动滚动", isOn: $writingAutoScroll)
                    Toggle("画完自动拉直线", isOn: $pencilLineSnap)
                    Picker("Pencil 轻点两下", selection: $pencilDoubleTapAction) {
                        Text("橡皮 ⇄ 上一支笔").tag("eraser")
                        Text("撤销").tag("undo")
                        Text("关闭").tag("off")
                    }
                    Picker("Pencil 挤压", selection: $pencilSqueezeAction) {
                        Text("弧形工具盘").tag("arc")
                        Text("橡皮 ⇄ 上一支笔").tag("eraser")
                        Text("关闭").tag("off")
                    }
                } header: {
                    Text("Pencil")
                } footer: {
                    Text("悬停预览:选词模式下把 Apple Pencil 悬停在单词上方,稍候显示迷你释义。触觉反馈:选词完成与加入生词本时给出轻触反馈(仅 Apple Pencil Pro / 妙控键盘触控板有效,手指与旧款 Pencil 无触觉)。「贴边自动滚动」:写字靠近屏幕上下边缘时自动滚页,写满一页可继续往下写。「擦完自动回笔」可在工具条右键菜单或这里切换。")
                }
                Section {
                    Button {
                        exportBackup()
                    } label: {
                        Label(backupState == .exporting ? "正在导出…" : "导出全部数据(备份 zip)", systemImage: "square.and.arrow.up")
                    }
                    .disabled(backupState != .idle)
                    Button {
                        showRestorePicker = true
                    } label: {
                        Label(backupState == .importing ? "正在恢复…" : "从备份恢复(覆盖当前数据)", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(backupState != .idle)
                } header: {
                    Text("数据(仅存本机)")
                } footer: {
                    Text("⚠️ 所有数据只保存在本机——删除 App 会全部丢失。请定期「导出全部数据」并通过「文件」App 保存到别处;重装或换机后可在同一入口恢复(会覆盖当前数据)。")
                }
                Section {
                    Button {
                        showStarDictPicker = true
                    } label: {
                        Label(dictImporting ? "正在导入词典…" : "导入 StarDict 词典", systemImage: "character.book.closed")
                    }
                    .disabled(dictImporting)
                    if userDictName != nil {
                        Button(role: .destructive) {
                            removeUserDictionary()
                        } label: {
                            Label("移除用户词典", systemImage: "trash")
                        }
                        .disabled(dictImporting)
                    }
                } header: {
                    Text("词典")
                } footer: {
                    Text(userDictName.map { "当前用户词典:\($0)(查词时优先命中)。" } ?? "支持 StarDict 三件套(.ifo/.idx/.dict 或 .dict.dz,可多选一起选),或打包成 .zip 直接选;导入后离线可用,查词优先命中用户词典。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.background1.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showRestorePicker) {
                ZipImportPicker { url in
                    pendingRestoreURL = url
                    showConfirmRestore = true
                }
            }
            .confirmationDialog("恢复将覆盖当前全部数据(生词本 / 高亮 / 手写 / 书签),确定?", isPresented: $showConfirmRestore, titleVisibility: .visible) {
                Button("恢复", role: .destructive) {
                    if let url = pendingRestoreURL {
                        restore(from: url)
                    }
                }
            }
            .sheet(item: $shareFile) { item in
                ActivityShareView(items: [item.url])
            }
            .alert("提示", isPresented: Binding(
                get: { restoreMessage != nil },
                set: { if !$0 { restoreMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(restoreMessage ?? "")
            }
            .sheet(isPresented: $showStarDictPicker) {
                StarDictPicker { urls in
                    importStarDict(urls)
                }
            }
            .onAppear {
                userDictName = DictionaryStore.shared.userDictionaryName()
            }
        }
    }

    // MARK: - StarDict 词典导入(v0.13.0)

    private func importStarDict(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        dictImporting = true
        Task { @MainActor in
            let result: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    let imported = try StarDictImporter.importDictionary(pickedFiles: urls) { _ in }
                    DictionaryStore.shared.reloadUserDictionary()
                    return "已导入词典「\(imported.bookName)」,共 \(imported.entryCount) 条。"
                } catch {
                    return "词典导入失败:\(error.localizedDescription)"
                }
            }.value
            dictImporting = false
            userDictName = DictionaryStore.shared.userDictionaryName()
            restoreMessage = result
        }
    }

    private func removeUserDictionary() {
        if let url = try? DictionaryStore.userDatabaseURL() {
            try? FileManager.default.removeItem(at: url)
        }
        DictionaryStore.shared.reloadUserDictionary()
        userDictName = nil
        restoreMessage = "已移除用户词典。"
    }

    // MARK: - 备份 / 恢复(v0.12.0,M7)

    private func exportBackup() {
        backupState = .exporting
        let db = self.db
        Task { @MainActor in
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
                try? BackupService.exportBackup(db: db)
            }.value
            backupState = .idle
            if let url {
                shareFile = ShareFileItem(url: url)
            } else {
                restoreMessage = "导出失败,请重试。"
            }
        }
    }

    private func restore(from url: URL) {
        backupState = .importing
        let db = self.db
        Task { @MainActor in
            let errorText: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    let snapshot = try BackupService.extractDatabase(from: url)
                    try db.replaceDatabase(withFileAt: snapshot)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            backupState = .idle
            if let errorText {
                restoreMessage = "恢复失败:\(errorText)"
            } else {
                restoreMessage = "数据已恢复。若界面未刷新,请返回文档库查看。"
                NotificationCenter.default.post(name: .yuewenDataDidRestore, object: nil)
            }
        }
    }
}

import SwiftUI

/// 设置页(v0.6.9 引入):先放「查词」开关,后续里程碑(Pencil 动作映射、OCR 引擎选择等)继续往里加。
/// 入口:文档库 ⚙️ 与阅读页 ⚙️。
struct SettingsView: View {
    /// v0.12.0(M7):数据备份/恢复需要数据库连接
    let db: AppDatabase

    @AppStorage("autoSpeakOnSelect") private var autoSpeakOnSelect = false
    @AppStorage("autoCollectOnSelect") private var autoCollectOnSelect = false
    @AppStorage("pencilHoverPreview") private var pencilHoverPreview = true
    @AppStorage("pencilHaptics") private var pencilHaptics = true
    @Environment(\.dismiss) private var dismiss

    private enum BackupState { case idle, exporting, importing }
    @State private var backupState: BackupState = .idle
    @State private var shareFile: ShareFileItem?
    @State private var showRestorePicker = false
    @State private var pendingRestoreURL: URL?
    @State private var showConfirmRestore = false
    @State private var restoreMessage: String?

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
                } header: {
                    Text("生词本")
                } footer: {
                    Text("开启后:选中的单词立即加入生词本并在页面上永久加亮,无需再点「加入生词本」。")
                }
                Section {
                    Toggle("Pencil 悬停预览", isOn: $pencilHoverPreview)
                    Toggle("触觉反馈", isOn: $pencilHaptics)
                } header: {
                    Text("Pencil")
                } footer: {
                    Text("悬停预览:选词模式下把 Apple Pencil 悬停在单词上方,稍候显示迷你释义。触觉反馈:选词完成与加入生词本时给出轻触反馈(仅 Apple Pencil Pro / 妙控键盘触控板有效,手指与旧款 Pencil 无触觉)。")
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
            }
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
        }
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

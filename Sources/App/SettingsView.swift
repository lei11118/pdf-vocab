import SwiftUI

/// 设置页(v0.6.9 引入):先放「查词」开关,后续里程碑(Pencil 动作映射、OCR 引擎选择等)继续往里加。
/// 入口:文档库 ⚙️ 与阅读页 ⚙️。
struct SettingsView: View {
    @AppStorage("autoSpeakOnSelect") private var autoSpeakOnSelect = false
    @Environment(\.dismiss) private var dismiss

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
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

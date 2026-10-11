import SwiftUI
import UIKit

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("运行状态") {
                    LabeledContent("版本", value: Self.versionString)
                    LabeledContent("里程碑", value: "M0 · 工程骨架 + GitHub Actions 出包")
                    LabeledContent("系统", value: "iPadOS \(UIDevice.current.systemVersion)")
                }

                Section("M0 已完成") {
                    Label("XcodeGen 工程定义(project.yml)", systemImage: "checkmark.seal")
                    Label("Actions 流水线:未签名 IPA + Release 发布", systemImage: "checkmark.seal")
                    Label("最低系统:iPadOS 17.5", systemImage: "checkmark.seal")
                    Label("依赖已就位:GRDB / ZIPFoundation", systemImage: "checkmark.seal")
                }

                Section("下一步 · M1") {
                    Text("PDF 导入与渲染、长按/拖选取词(手指与 Pencil)、临时加亮")
                        .foregroundStyle(.secondary)
                }

                Section("说明") {
                    Text("纯本地工具:无账号、无云同步、无广告、无内购。所有数据仅保存在本机。")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("读词")
        }
    }

    private static var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

#Preview {
    ContentView()
}

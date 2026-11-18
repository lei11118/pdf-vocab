import SwiftUI

struct TranslationModelsView: View {
    @ObservedObject private var manager = TranslationModelManager.shared
    @AppStorage(TranslationModel.preferenceKey) private var modelID = TranslationModel.systemID

    var body: some View {
        Form {
            Section("系统翻译") {
                Button {
                    modelID = TranslationModel.systemID
                    Task { await LocalContextTranslation.shared.evict() }
                } label: {
                    HStack {
                        Text("Apple Translation")
                        Spacer()
                        if modelID == TranslationModel.systemID { Image(systemName: "checkmark") }
                    }
                }
                .disabled(manager.enabling != nil)
                OfflineTranslationPreparationView()
            }
            Section {
                if TranslationModel.available.isEmpty {
                    Text("此设备暂无通过验证的可下载模型。")
                        .foregroundStyle(.secondary)
                }
                ForEach(TranslationModel.available) { model in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.name).font(.headline)
                            Spacer()
                            if modelID == model.id {
                                Image(systemName: "checkmark").accessibilityLabel("正在使用")
                            }
                        }
                        Text("\(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)) · 端侧 · Apache-2.0")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Link("权重来源与许可", destination: model.sourceURL)
                            .font(.footnote)
                        if let progress = manager.progress[model.id] {
                            ProgressView(value: progress)
                            Button("暂停下载") { manager.pause(model) }
                        } else if manager.installed.contains(model.id) {
                            HStack {
                                if manager.enabling == model.id {
                                    ProgressView("正在检查模型")
                                } else if modelID != model.id {
                                    Button("启用") { Task { await manager.enable(model) } }
                                }
                                Button("删除下载", role: .destructive) {
                                    Task { await manager.remove(model) }
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(manager.enabling != nil)
                        } else {
                            Button(manager.messages[model.id] == nil ? "下载" : "继续或重试") {
                                manager.download(model)
                            }
                        }
                        if let message = manager.messages[model.id] {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("可下载模型")
            } footer: {
                #if DEBUG
                if !TranslationModel.available.isEmpty {
                    Text("开发构建中的端侧候选，等待实体 iPad 性能与功耗验收。")
                }
                #endif
            }
        }
        .navigationTitle("翻译模型")
    }
}

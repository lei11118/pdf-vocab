import SwiftUI

struct WorkspaceFolderEditor: View {
    @Environment(\.dismiss) private var dismiss
    let folder: WorkspaceFolder?
    let onSave: (String, String) -> Void
    @State private var name: String
    @State private var icon: String
    init(folder: WorkspaceFolder?, onSave: @escaping (String, String) -> Void) {
        self.folder = folder; self.onSave = onSave
        _name = State(initialValue: folder?.name ?? "")
        _icon = State(initialValue: folder?.icon ?? "folder")
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    Label(name.isEmpty ? "新文件夹" : name, systemImage: icon)
                        .font(DS.Fonts.title2).foregroundStyle(DS.accent)
                        .frame(maxWidth: .infinity, minHeight: 100)
                    TextField("文件夹名称", text: $name)
                        .padding(18).background(DSReliefSurface(radius: 18, inset: true))
                        .accessibilityLabel("文件夹名称")
                    Text("文件夹图标").font(DS.Fonts.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 16) {
                        ForEach(WorkspaceFolder.icons, id: \.self) { symbol in
                            Button { icon = symbol } label: {
                                Image(systemName: symbol).font(.system(size: 24))
                                    .foregroundStyle(DS.accent).frame(width: 56, height: 56)
                                    .background(DSReliefSurface(radius: 18, inset: icon == symbol))
                            }.buttonStyle(DSPressableButtonStyle())
                            .accessibilityLabel(symbol)
                            .accessibilityAddTraits(icon == symbol ? .isSelected : [])
                        }
                    }
                    Button("保存文件夹") { onSave(name, icon) }
                        .buttonStyle(DSPillButtonStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(24)
            }.background(DS.background1)
                .navigationTitle(folder == nil ? "新建文件夹" : "编辑文件夹")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }.tint(DS.accent)
    }
}

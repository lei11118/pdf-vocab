# 知识图谱、弧形工具盘与词典组合

本次沿用 SwiftUI / UIKit、PDFKit、PencilKit、Vision、GRDB、系统朗读；不改变现有墨迹引擎的笔刷效果。

## 实施范围与入口

| 阶段 | 源码 | 行为 |
|---|---|---|
| M1 | `ReaderView`、`SettingsView` | 阅读模式 / 标记模式；兼容原有按文档保存的 Boolean 模式键，无须清除用户设置 |
| M2–M3 | `ToolArcConfig`、`PencilArcMenu`、`ReaderCoordinator` | 45°、双层、左右手镜像、极坐标命中、单侧悬停展开；捏压松开触发；译文显示时优先朗读；按钮提供降级入口 |
| M4–M5 | `KnowledgeGraph.swift`、`KnowledgeGraphView` | 每文档画布、文本/标记/截图节点、手动连线、独立撤销、层级、移动与调整尺寸、视口保存 |
| M6 | `GraphCapture`、`ReaderView` | 源 PDF 重渲染与已有墨迹合成，框选后可调整；截图入图而不跳转；源文字优先、Vision 后备 |
| M7 | `WordInteractionLayer`、`HoverTipView` | 页面保留精确字形/链接手势适配器，文本和截图提供词框适配器；共用查词、悬停防抖、取消过期结果、译文气泡、捏压朗读状态机 |
| M8 | `KnowledgeGraphStore`、`BackupService` | 原生词备份后按文档出处迁移成文本节点；原查词历史不删除；图谱 JSON 进入现有数据库，截图及缩略图使用沙盒相对文件名并随备份导出 |
| 词典组合 | `DictionaryCatalog`、`DictionaryStore`、`StarDictImporter` | 多部导入独立保存；各来源独立开关，合并时保留来源，不再首条命中即覆盖其余来源 |

文档库的图谱入口先选择文档。阅读页侧栏可直接打开当前文档图谱。节点顶部拖动移动节点；侧边连接点拖动连线，四角调整大小；“选择/移动”可直接拖动整个节点。文本默认阅读，双击编辑。Pencil 在已选中的标记框内书写，手指不画墨迹。

## 词典来源与覆盖边界

- ECDICT 1.0.28 完整源数据按显式学科标签提取：数学、物理、化学、医学、生物、计算机、工程、地球科学。它们是同一来源的学科子库，不冒充八部独立出版词典，类别可以重叠，且未标注的专业词不会自动归类。
- `scripts/build_science.py` 可重建；`Resources/ScienceSources/manifest.json` 记录来源、转换规则与各类计数，附 MIT 原文。
- Open English WordNet 2025 使用现有 `lexical.sqlite` 的英文义项补充英汉库；不能把其英英定义称为中文翻译。原 WordNet / CC BY 4.0 授权与来源保留于 `Resources/LexicalSources`。
- 用户可在设置中组合启用任意来源，继续导入合法持有的 StarDict；每次生成独立 UUID 文件。旧 `userdict.sqlite` 原位保留并纳入组合。

## 验证

`test-ink` Actions 使用 Xcode 26.6 的 iPad 模拟器执行回归与渲染截图；`build-ipa` 生成未签名 arm64 IPA。Windows 无法本地执行 Xcode。

新增用例覆盖：无向连线去重与级联删除、图谱编解码、弧盘镜像/弦中点/极坐标、空白处不吸附到词、资源路径边界、旋转 PDF 截图词框、专业资源随包、独立导入组合开关、过期悬停取消。原 PDF 字形与链接长按用例继续保留。

实机验收仍需覆盖：Pencil Pro 捏压事件路由、手掌/手指与画布操作、文本拖选和链接长按、分屏/旋转、200+ 节点性能、120Hz 动画、应用后台与强制终止恢复。模拟器截图与通过测试不能替代这些硬件验收。

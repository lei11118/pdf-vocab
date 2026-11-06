# v0.71.0-beta 测试说明

版本配置：`0.71.0`（build `121`）
候选提交：`43a63c9700fe9be9a184832340f9b6f0df84c789`
用途：内部测试候选。

## 当前构建与测试证据

- [`build-ipa run 42182468504`](https://github.com/lei11118/pdf-vocab/actions/runs/42182468504) 在提交 `43a63c9700fe9be9a184832340f9b6f0df84c789` 上成功。IPA 版本/build 为 `0.71.0 / 121`，minimum OS 为 `26.0`，文件大小 `48,075,418 bytes`，SHA-256：`ef33542468c1d065a0e5a60d0501433891d422fdff67c6bb7b5f01740edd50e7`。主 app ZIP CRC、ARM64 架构和 science/ecdict 资源头检查通过。
- [`test-ink run 42182468786`](https://github.com/lei11118/pdf-vocab/actions/runs/42182468786) 在同 SHA `43a63c9700fe9be9a184832340f9b6f0df84c789` 上成功：223 项 unit/integration + 6 项 UI，共 229 项，零失败（`TEST SUCCEEDED`）。`ContextualTranslationAlignment` 9 项、`ContextualTranslationService` 5 项、`ReaderEdgeGaussianBlur` 4 项和 `SentenceContextBuilder` 13 项均通过。
- 初始实现提交 `a487108` 的构建检查发现两处 Swift 编译问题：语境任务视图里的嵌套 `State` 名称与 SwiftUI `@State` 属性包装器冲突；对 attributed run 范围转换 `String.Index` 时使用了 `attributed` 包装值。后续提交 `43a63c9` 将状态类型改名为 `TranslationState`，并改为以 `attributedText` 计算索引。上述构建成功证据适用于修正后的 SHA。
- 本次 UIReview 共生成 44 张 PNG；主脑抽查 reader-canvas portrait/landscape、context-card light、narrow-dark 四张图。静态画面无明显裁切或旧矩形挡条，浅/深语境卡均未显示原句或整句译文；卡片截图处于开关关闭的词典回退状态，只证明该布局，不证明 Apple 候选译义或动态 Gaussian 质量。真实 iPad/iPadOS 26.4+ 验收仍待完成。

## 实际验证命令与结果

- `gh run view 42182468786 --log` → 223 项 unit/integration + 6 项 UI，零失败，`TEST SUCCEEDED`；run SHA 与 `43a63c9700fe9be9a184832340f9b6f0df84c789` 一致。
- `gh run view 42182468504 --json conclusion,headSha` → `success`，head SHA 为 `43a63c9`。
- Python 标准库 `zipfile.testzip()`、`plistlib`、`hashlib`（读取 IPA 内精确主 app `Info.plist`）→ 版本/build/minimum OS、主 app ZIP CRC、ARM64 与 science/ecdict 资源头检查通过；IPA 为 48,075,418 bytes，SHA-256 `ef33542468c1d065a0e5a60d0501433891d422fdff67c6bb7b5f01740edd50e7`。

## 本次增量

- **Reader 安全区模糊层**：顶部和底部安全区从系统材质改为 PDF 阅读画面的 Gaussian 模糊层。UIKit 画面采集在主线程，Core Image 模糊在后台队列。需要检查页面更新、边缘黑框、滚动缩放时的性能。
- **原生 PDF 句子上下文**：根据 PDFKit 选区的原文 UTF-16 ranges 定位唯一句子并保留原文坐标；只有选区与显示 surface 的非空白字符完全一致才构造 context，句子上限为 2048 UTF-16 单元。跨行仅在相邻且同栏几何通过校验时连接。
- **OCR 句子上下文**：仅用原文完整且可映射的单条 OCR 行构建 context。片段保持 fragment；OCR 跨行 context 暂不提供。
- **单 Token 语境卡候选**：完整 context 的单 Token 语境卡可请求 iPadOS 26.4+ 的系统 attributed-token 对齐候选，界面标注“系统对齐，待校对”。多词选区继续走现有整句卡；Reader 悬浮预览和小胶囊仍显示词典释义。
- **实验开关与回退**：设置页“语境 Token 阅读”默认关闭。context 不完整、不可信或系统候选不可用时，不发候选请求；语境卡保留现有“查看词典释义”入口。数学识别暂未开放。
- **语言准备**：候选请求使用英语 `en` → 简体中文 `zh-Hans`。系统状态为 `supported` 时提示用户手动准备离线翻译；“可准备”不代表“已安装”。

## 19 个改动文件：分组、原因与验证映射

以下路径对应提交 `a487108` 的 19 个文件。提交 `43a63c9` 修正了其中两个翻译文件的编译问题。

### Reader 设置、卡片与路由

**路径：**
`Sources/App/SettingsView.swift`、`Sources/Card/ContextualTranslationTaskView.swift`、`Sources/Card/WordCardView.swift`、`Sources/Reader/ReaderView.swift`

**原因：** 默认关闭语境 Token 实验开关；将符合条件的单 Token 选区接入语境卡；完整 context 才请求系统候选，并保留词典回退。多词选区沿用旧整句卡，悬浮预览和小胶囊仍显示词典释义。

**验证映射：** `Tests/ContextReadingTests.swift` 的 default-off 用例验证实验开关默认关闭。本次 6 项 UI 测试是既有导航、布局和手势回归，不驱动本次 SwiftUI `TranslationSession` 候选流程。完整 run 42182468786 已通过。

### 原生与 OCR 句子上下文

**路径：**
`Sources/ContextReading/ContextSelectionRouter.swift`、`Sources/ContextReading/Models/SourceModels.swift`、`Sources/ContextReading/OCR/ContextOCRSelectionSource.swift`、`Sources/ContextReading/SentenceContextBuilder.swift`

**原因：** 在选区模型中携带 sentence context；原生 PDF 按精确 source ranges 构建句子；OCR 只将完整可映射的单行原文标为完整句，保留片段类型。

**验证映射：** `Tests/ContextReadingTests.swift`、`Tests/ContextOCRSelectionTests.swift`、`Tests/SentenceContextBuilderTests.swift` 覆盖模型、原文/显示映射、OCR fragment 和句子定位边界。完整 `test-ink` run 42182468786 已通过（223 项 unit/integration + 6 项 UI，零失败）。

### Token 对齐与候选服务

**路径：**
`Sources/ContextReading/ContextualTranslationAlignment.swift`、`Sources/ContextReading/ContextualTranslationService.swift`

**原因：** 校验输入和选中 Token 范围，保留 attributed Token 标记，提取对应候选，并管理有限内存缓存与过期请求。

**验证映射：** `Tests/ContextualTranslationTests.swift` 的 14 项是纯值对齐与 service 生命周期测试：`ContextualTranslationAlignment` 9 项、`ContextualTranslationService` 5 项。它们不驱动真实 SwiftUI `TranslationSession`，也不覆盖 `ContextualTranslationTaskView` 多窗口竞态；真实 Apple attributed-range/译义行为仍待核对。run 42182468786 已通过。

### Reader Gaussian 安全区层

**路径：**
`Sources/Reader/ReaderEdgeGaussianBlur.swift`

**原因：** 从 PDF 阅读画面采集缩小图像，异步执行 Core Image Gaussian 模糊，并用渐变遮罩绘制安全区边缘层。

**验证映射：** `Tests/ReaderEdgeGaussianBlurTests.swift` 的 4 项覆盖布局、渐变遮罩和 Gaussian 边缘像素，不覆盖 view 生命周期、持续滚动性能、内存或发热。run 42182468786 已通过；这些设备表现仍需真机验证。

### 新增或扩充的测试文件

**路径：**
`Tests/ContextOCRSelectionTests.swift`、`Tests/ContextReadingTests.swift`、`Tests/ContextualTranslationTests.swift`、`Tests/ReaderEdgeGaussianBlurTests.swift`、`Tests/SentenceContextBuilderTests.swift`

**原因：** 为 OCR/native selection context、Token attributed-range 对齐、请求状态及 Gaussian 处理补充回归覆盖。

**验证映射：** 完整 run 42182468786 已通过，共 223 项 unit/integration 与 6 项 UI，零失败。6 项 UI 是既有导航/布局/手势回归；通过不代表系统候选界面或 SwiftUI TranslationSession 已在 UI 测试中验收。

### 版本与文档

**路径：**
`project.yml`、`docs/BETA-0.71.0-TESTING.md`、`docs/CONTEXT-READING-IMPLEMENTATION.md`

**原因：** 配置 v0.71.0/build121，并记录验收步骤、当前实现边界和历史证据。

**验证映射：** `build-ipa` run 42182468504 与 IPA 元数据核对了版本/build/minimum OS；主 app ZIP CRC、ARM64 和 science/ecdict 资源头检查通过。文档本身不替代行为测试。

## 测试步骤

1. **完整 CI**：`test-ink` run 42182468786 在 SHA `43a63c9700fe9be9a184832340f9b6f0df84c789` 上通过，223 项 unit/integration + 6 项 UI，零失败；`build-ipa` run 42182468504 也通过。本次 44 张 UIReview PNG 中主脑已审阅 4 张代表图，结论仅限静态布局；这些验证不替代真机检查。
2. **默认关闭与原有卡片**：确认实验开关默认关闭，不发语境候选请求；普通单词卡、整句卡、悬浮预览、小胶囊和词典查询继续可用。
3. **原生 PDF 选区**：在单栏 PDF 选取完整句中的单词，核对上下文落在当前 occurrence；覆盖重复词、surface/source 不匹配、空行、双栏跳转及不完整片段。跨正常换行时只有几何验证通过才连接。
4. **OCR 选区**：分别选取完整单行 OCR 句和无终止标点片段；前者可进入候选准备，后者保持 fragment 并可打开词典。跨 OCR 行不得误标为完整句子。
5. **候选入口范围**：仅在完整语境的单 Token 语境卡检查系统候选。悬浮预览和小胶囊继续检查词典释义，多词选区继续检查旧整句卡。人工校对候选与 source/target attributed ranges。
6. **系统版本与语言包**：在 iPadOS 26.4+ 覆盖 `.installed`、`.supported`、`.unsupported`、准备取消/失败/重试及安装后刷新。必须由用户显式启动语言准备。
7. **词典回退**：覆盖开关关闭、低于 iOS 26.4、句子不完整、context 不可信、语言不支持和 Token 未对齐；确认可打开原词典卡并返回。
8. **Gaussian 边缘层**：横竖屏、分屏、滚动、缩放、翻页、切文档和前后台切换检查更新、黑边、遮挡及持续滚动表现。真实设备性能仍需 iPad 验收。

## 尚待完成

- OCR 跨行句子上下文与相邻行/同栏几何校验。
- GRDB 句子/译义候选持久化及迁移；当前语境翻译候选仅走内存服务缓存。
- 建立人工标注金标集并报告 Token 对齐 precision、recall、F1。
- 真实 iPad/iPadOS 26.4+ 上的 Apple Translation 候选、语言包准备、动态 Gaussian 表现、流畅度、耗电与响应仍待验证。

在这些检查完成前，v0.71.0 仍是候选版本。不得将历史 CI、合成样例或当前运行中的测试写成通过证据。

# ★标记★ v0.72.0 测试版验收

## 构建

- 应用源码：`440d08d9593c3e466707200a20a931e94d63d64a`，版本 `0.72.0` / build `123`，最低 iPadOS `26.0`。
- [build-ipa 42367236564](https://github.com/lei11118/pdf-vocab/actions/runs/42367236564) 成功；未签名 IPA 需用 AltStore / SideStore 自签。
- CI 包校验及下载后独立校验：ZIP CRC 通过；主程序 ARM64 Mach-O；`ecdict.sqlite`、`science.sqlite`、`lexical.sqlite` 文件头通过。
- IPA 大小：48,159,484 bytes；SHA-256：`84be36fe83031f27b62c46823a249807c23c254cc6ab6a3b21cd0e647c875364`。
- [全量 test-ink 42367223532](https://github.com/lei11118/pdf-vocab/actions/runs/42367223532) 成功：276 项 unit/integration + 7 项 UI，共 283 项，零失败。

## 本轮改动与自动化范围

- `LayoutBlockContextBuilder.swift`：按可信行、栏位和结构边界组装有界上下文，不要求标点构成完整句子；保持原文 UTF-16 范围，避免重复词错配。
- `ContextualTranslationAlignment.swift`：校验 OCR 行内范围到语境块范围的映射；不可靠映射拒绝生成语境候选。
- `ContextualTranslationService.swift`：复用已验证的语境块翻译 payload，每次按当前所选 Token 重新提取候选；缓存失配重新请求。
- `WordCardView.swift`、`HoverTipView.swift`：语境译义和词典释义在同一窗口，长内容共用滚动区域。
- 新增单元测试覆盖跨栏、结构边界、Unicode、重复词、范围映射、缓存隔离和窗口内容；真实雅思扫描裁剪图测试调用 Vision OCR，再验证选词到语境请求的链路。
- CI 验证命令：`xcodebuild test -project PdfVocab.xcodeproj -scheme PdfVocab -configuration Debug -destination "platform=iOS Simulator,id=$DEVICE" -resultBundlePath build/InkTests.xcresult CODE_SIGNING_ALLOWED=NO`；`$DEVICE` 由 `test-ink` workflow 选择。
- `--context-display-audit` 的两个 DEBUG 展示使用固定长文本检查同屏滚动，并随 UIReview 截图验证；固定候选文本是布局夹具，不是 Apple 模型返回的译义。
- 研究、候选开源方案和两本 PDF 的取样方法见 [布局语境证据](CONTEXT-BLOCK-ALIGNMENT.md)。识别器本身没有更换，不声称整本扫描书 OCR 精度已提升。

## iPad 手动验收

1. 在设置中开启默认关闭的“语境 Token 阅读”。系统语境对齐需 iPadOS 26.4+；先准备英语到简体中文的 Apple 离线语言包。语言包未准备或系统不支持时，应保留词典释义与明确状态。
2. 在 Halliday 文字层 PDF 中长按或双击正文词/已验证短语，核对蓝色选区与原文一致；跨行、同一词多次出现、双栏题目均检查。单击链接仍正常跳转，长按链接应可选取。
3. 在 IELTS 扫描 PDF 中等当前页 OCR 完成，再悬浮与选词；检查黄色提示框、原文位置与语境候选；不应混入另一栏或相邻题目。低可信映射应明确回退词典，而非展示错误候选。
4. 悬浮窗口、选词胶囊和词卡都检查语境译义与词典中文释义同时可见；长释义可在同一窗口滚动，不进入二级词典页。原句及整句译文不应冒充所选 Token 词义。
5. 在同一语境块连续选择不同词、快速切换页和关闭实验开关；旧候选不应覆盖新选词。检查语言包缺失、取消准备和断网状态。
6. 回归尺子位置/旋转、Pencil 手势、弧形工具栏、独立窗口拖动缩放及阅读/标记模式；本轮没有主动修改这些交互。

## 未完成的验收

真实 iPad 的 Apple attributed translation 属性回传、语义准确度、全书 OCR 准确率、耗时与功耗尚未验证。自动化使用模拟翻译 payload 的对齐测试不能替代真实系统模型测试。数学识别、外部模型端侧部署与安全阶段未完成。

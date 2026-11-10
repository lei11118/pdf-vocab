# ★标记★ v0.73.0 / build 124 测试版候选

> 当前可用测试包来自 [build-ipa run 42819256727](https://github.com/lei11118/pdf-vocab/actions/runs/42819256727)，提交 `45cd4b2a17b4df40f0c49ffa5f9ea51b357e25d6`。unsigned IPA 为 52,762,710 bytes，SHA-256 `b8a2fd60e6cc170a96fe79a9e329aa6e5699f9db0d9467f367713595a87f43aa`；独立审计确认 CRC 63、arm64、0.73.0/build 124、minimum iOS 26.0，包内无模型。

## 当前 CI 与产物

- **IPA 构建**：[build-ipa run 42819256727](https://github.com/lei11118/pdf-vocab/actions/runs/42819256727) 成功，构建提交 `45cd4b2a17b4df40f0c49ffa5f9ea51b357e25d6`。实际 IPA 的 Info.plist 为 `com.lei11118.pdfvocab`、v0.73.0、build 124、minimum iOS 26.0；文件大小 52,762,710 bytes，SHA-256 `b8a2fd60e6cc170a96fe79a9e329aa6e5699f9db0d9467f367713595a87f43aa`。独立包审计确认 CRC 63、arm64 且包内无模型。
- **安装方式**：这是 unsigned IPA。在 iPadOS 26.0 或更高版本上，使用 AltStore 或 SideStore 导入并自签侧载。
- **Focused UI**：[test-ink run 42819124823](https://github.com/lei11118/pdf-vocab/actions/runs/42819124823) 在与 IPA 相同的 SHA `45cd4b2a17b4df40f0c49ffa5f9ea51b357e25d6` 上 2/2 通过；连续拖选完整公式严格断言及完整公式交互通过。另一用例中系统英语→简体中文仍为 unsupported，实际译文未验证；Vision OCR 路径通过。结果来自模拟器，不代表真实 iPad/Pencil 验收。
- **全量测试**：同 SHA 的 [test-ink run 42819134564](https://github.com/lei11118/pdf-vocab/actions/runs/42819134564) 已成功；301 项单元/集成和 9 项 UI 测试全部通过（0 failures，`TEST SUCCEEDED`）。
- **独立模型评估**：[run 42603665321](https://github.com/lei11118/pdf-vocab/actions/runs/42603665321) 的真实 CPU 推理 5/5 样本均生成到 EOS，但空白归一化后的严格匹配为 0/5，资格 run 失败。评估仅为独立资格流程，模型未集成进 app。

## 历史包与回归记录

- 前一 build 124 unsigned IPA 来自 [build-ipa run 42609989231](https://github.com/lei11118/pdf-vocab/actions/runs/42609989231)，提交 `535d8e3025195026c9ddeeb330d716cb93c0610a`，文件名 `PdfVocab-unsigned.ipa`，52,760,873 bytes，SHA-256 `3e8daac4293fe2b9923102004ac98aa5b033c9d08f5ba9cd022297b6c1d4aa22`；已由当前 run 42819256727 的 IPA 取代。
- 上一候选的 [unit-only run 42610546878](https://github.com/lei11118/pdf-vocab/actions/runs/42610546878) 为 301/301；[full run 42611063500](https://github.com/lei11118/pdf-vocab/actions/runs/42611063500) 为 301/301 单元/集成通过、7/8 UI，完整公式连续拖选失败。test 提交 `d925c0e`、`702417b` 相对旧 IPA `535d8e3` 的 `Sources/`、`Resources/` 与 `project.yml` 无差异。
- 前序 focused run [42810625318](https://github.com/lei11118/pdf-vocab/actions/runs/42810625318) 曾在 attempt 2 失败于连续公式拖选；attempt 1 启动超时，attempt 2 的原始手势日志和模拟器局限见 [实施现状文档](CONTEXT-READING-IMPLEMENTATION.md) 的历史失败诊断。本次 focused run `42819124823` 已在新 SHA 上通过同一严格断言。
- 较早 Focused UI [run 42610948656](https://github.com/lei11118/pdf-vocab/actions/runs/42610948656) 最终失败；attempt 2 未能选中完整公式，后续翻译和扫描步骤未到达。[run 42616691635](https://github.com/lei11118/pdf-vocab/actions/runs/42616691635) 的 AX 附件记录 `selectedText: ²`，该值仅属于该前序 run。
- 更早 unsigned IPA 来自 [build-ipa run 42492945297](https://github.com/lei11118/pdf-vocab/actions/runs/42492945297)，构建提交 `444240051f5ce54ce15637e48c0c1423001b6c1e`，文件名 `PdfVocab-unsigned.ipa`，52,760,513 bytes，SHA-256 `d3dc4eedd9b74347392ab16726960aa8e5af01810641bfe5490e57dcf9c700a4`；随后先由 run 42609989231、再由当前 run 42819256727 的 IPA 取代。
- [test-ink run 42604142252](https://github.com/lei11118/pdf-vocab/actions/runs/42604142252) 测试提交 `c017e0fa03bf75454b2e3d3c1f667aa042947162` 已完成但失败：301 项中 1 项断言把 AST 保留的 Unicode 数学减号 `−3` 错期望为 ASCII `-3`；随后在 run 42610546878 中以正确期望重跑，301 项全部通过。该旧 run 的 8 项 UI 测试有 7 项通过，真人阅读流程一个用例的 4 项断言失败；流程的翻译与扫描步骤未到达。该 UI 结果属于较早 app 提交，不代表当前 build-ipa 提交 `45cd4b2` 的 UI 结果。
- 更早候选 `6522832` 的 [test-ink run 42490333622](https://github.com/lei11118/pdf-vocab/actions/runs/42490333622) 与 [build-ipa run 42490333408](https://github.com/lei11118/pdf-vocab/actions/runs/42490333408) 因私有 enum 使用 Swift 关键字 `subscript` 作为 case 而编译失败；测试未开始且没有 IPA。后续已改为 `subscriptValue`，该候选已被取代。

## 候选内容与边界

- **数学文本解析**：使用固定 SwiftMath revision 将传入数学文本解析为 LaTeX 与结构 AST；区分 `x`/`×`、`l`/`1`、`ν`/`v`、`ψ`/`Ψ` 及 epsilon/phi 字形。数学开关默认关闭，并受语境阅读总开关约束。此功能解析文字中的公式语法，不做公式图片 OCR，也不证明 PDF/OCR 提取的公式准确。
- **语境翻译持久缓存**：GRDB `v16.contextTranslationPayloads` 建立 `context_translation_payload`。缓存身份包含文档 SHA、源文本与 Token/短语范围、源/目标语言、backend/system-version identity、上下文算法版本和快照 schema 版本。采用 LRU，单 payload 上限 256 KiB、总量上限 16 MiB；超限不阻断翻译。
- **Reader 交互审查**：`testHumanReadingAuditUsesLiveReaderDictionaryAndMath` 与 `testHumanReadingAuditUsesLiveTranslationSearchZoomLayoutAndVisionOCR` 通过真实 Reader/DocumentStore 路由生成 searchable-native PDF 与 raster-only PDF，覆盖交互路径；它们是合成夹具，raster 路径使用现有 Vision OCR，不是公式图片识别评测。
- **G4 对齐评测**：当前只有合成构造的 spans/marker attributes 与指标算术测试；真实人工标注 gold 集尚未建立。数学合成公式的 expected 值不属于 G4 译义 gold。真实 Apple Translation 返回内容的词义与对齐质量仍待校对。

## 测试证据分开记录

| 证据 | 测试来源 | 能说明什么 |
|---|---|---|
| Reader 合成交互 | `ReaderRouteUITests` 的 native 与 raster-only PDF 夹具 | Reader 路由和交互链路；不是现实扫描文档的总体精度 |
| 真实 IELTS 两行 OCR | `RealScanContextTests` 的单张 `IELTS-context-strip` 裁剪图；同 SHA full run 42819134564 记录 CER `0.019` / WER `0.105` | 单样本 Vision OCR 与选词上下文链路；不是整本或一般扫描页精度 |
| OpenStax native PDF | `RealPDFSelectionTests` 的文字层 PDF | 既有 PDFKit 原生文字选择回归；与 IELTS OCR 和合成 raster 用例分开 |

## 已验证与待重测项目

| 环境 | 已验证 | 待重测或未验证 |
|---|---|---|
| 单元/集成目标（iPad Pro 13-inch M5、iOS 26.5 模拟器） | 当前 SHA full run 42819134564 为 301/301 通过；历史 run 42610546878 和 42611063500 仅代表旧候选 | 无当前 SHA 的单元/集成失败；真机验收仍待完成 |
| Reader UI（iPad Pro 13-inch M5、iOS 26.5 模拟器） | 当前 SHA focused run 42819124823 为 2/2 通过，full run 42819134564 为 9/9 通过；连续拖选公式严格断言及完整公式交互通过。另一用例中系统英语→简体中文 unsupported，实际译文未验证，Vision OCR 路径通过 | 真实 iPad / Apple Pencil 和实际翻译内容仍待验收 |
| 真实 iPad / Apple Pencil | 本次 CI 没有真实设备证据 | 在设备上复验下面三条 Reader 路径；模拟器结果不能代替实机确认 |

真实 iPad / Apple Pencil 复验路径：

1. **原生 PDF 与链接**：打开带文字层的原生 PDF，验证普通文字选择、词典双击，以及链接单击与长按选择能按预期区分并可返回阅读。
2. **扫描 PDF 与悬浮合并译义**：打开扫描 PDF，选中单词或短语，检查 OCR 选区定位、悬浮面板中的上下文合并译义，以及滚动页面后选区和译义是否仍对应。
3. **公式文本与词卡缩放**：选择包含公式文本的行，检查公式解析显示；打开词卡并缩放或改变阅读区域，确认公式与词卡内容可读且布局稳定。

## 尚待验收

- 当前 SHA 的 focused run 42819124823（2/2）与 full run 42819134564（301/301 单元/集成、9/9 UI）均通过；完整公式连续拖选及后续交互通过。真实 iPad / Apple Pencil 行为尚未验证，系统英语→简体中文状态为 unsupported，实际译文未验证。
- 上述三条真实 iPad / Apple Pencil Reader 路径尚未完成实机验收。
- 真实 Apple Translation 译义与 attributed-token 对齐仍需人工核验并建立金标。
- 整本、多样本 OCR 质量尚未验证；单张裁剪图结果不可外推。
- 数学文本解析不验证原 PDF/OCR 的识别结果；公式图像识别和外部模型集成仍未完成。

# ★标记★ 语境布局块与翻译对齐证据

> 状态：v0.72.0 / build 123 在研记录，核对日期 2026-11-07。当前增量提交为 `440d08d9593c3e466707200a20a931e94d63d64a`。[test-ink run 42367223532](https://github.com/lei11118/pdf-vocab/actions/runs/42367223532) 已通过：276 项 unit/integration + 7 项 UI，共 283 项，零失败；同 SHA 的 [build-ipa run 42367236564](https://github.com/lei11118/pdf-vocab/actions/runs/42367236564) 成功产出 IPA，大小 48,159,484 bytes，SHA-256 `84be36fe83031f27b62c46823a249807c23c254cc6ab6a3b21cd0e647c875364`。前一候选和中间提交的失败记录见“验证状态”，均为历史结果。本文记录已检查的源码、样本与官方资料，不代表质量或真机验收完成。

## 本轮决策

- 保留已有的 Apple `TranslationSession` attributed-string 路径和项目自定义 Token ID 属性。Apple 文档说明 `translate(AttributedString)` 会保留格式及自定义属性；当前代码仍以 `iOS 26.4` 可用性检查保护请求。此处复用现有候选能力，不宣称真实 iPad 上的译义或 Token 对齐已验收。
- 保留当前 Vision `.accurate` 识别的词级框，以及已有的原文 UTF-16 / DP 对齐与 `verifiedCharacter` 完整性门槛。新增代码只把有界的 PDF 行布局和列几何接到上下文构造；不将 Vision 词框冒称字符框，也不让外部模型替换现有翻译对齐路径。
- 只有可信行几何、同列邻接关系和源文本映射都通过验证时，才生成 `.layoutBlock`。编号题目、标题、公式等结构边界会截断上下文；长度受 2,048 UTF-16 单元上限约束，OCR 邻接扩展当前至多检查每侧 8 行。其他情况继续使用现有回退路径。该实现已纳入 `eb728dc`；当前测试结果见“验证状态”，尚不构成最终验收。
- `Apple Vision RecognizeDocumentsRequest`、PaddleOCR PP-StructureV3、awesome-align 和 SimAlign 都是评估候选；本轮未接入它们。对齐方案先复用 Apple Translation attributes 和已有几何 / DP 校验，避免再加入一个独立模型输出协议。

相关代码：`Sources/ContextReading/LayoutBlockContextBuilder.swift`、`Sources/ContextReading/SentenceContextBuilder.swift`、`Sources/ContextReading/OCR/ContextOCRSelectionSource.swift`、`Sources/ContextReading/ContextualTranslationAlignment.swift`、`Sources/Card/ContextualTranslationTaskView.swift`。该增量已提交；当前 CI 状态见“验证状态”。

## PDF 样本事实

两份用户本地 PDF 均未复制进仓库。页数由 `pdfinfo` 核对；整本文字层覆盖由 bundled Python 的 `pypdf` `Page.extract_text()` 逐页统计。以下计数只说明 API 能否提取到文本，不说明文字正确、版面顺序正确或 PDFKit 会返回同样结果。

| 样本 | 页数 | 文字层观察 | 代表页与媒体框 |
|---|---:|---|---|
| IELTS workbook | 205 | 仅 1/205 页非空（约 0.5%）；唯一非空页是末页书目信息，正文扫描页没有可抽取文字。 | PDF 第 10 页（书印第 6 页）为引言双栏正文；第 50 页（书印第 46 页）为编号练习、字格和图表。两页 MediaBox 均为 558.7086 × 768 pt。 |
| Halliday / Resnick physics | 1,453 | 1,452/1,453 页非空（约 99.9%），共 5,570,625 个提取字符；1,407 页超过 2,000 字符。pypdf 对若干 CFF Type1 字体发出缺少 `fontTools` 的解析警告，因此这里不把覆盖率当作字符准确率。 | PDF 第 61 页（书印第 33 页）含双栏题目、模块标题和图注；第 88 页（书印第 60 页）含双栏向量题。两页 MediaBox 为 732 × 849 pt，CropBox 为 `[32.98, 32.98, 699.02, 816.02]`。 |

physics 文件首页 MediaBox 为 666 × 783.36 pt；`pdfinfo` 的整本摘要显示首页尺寸。第 61/88 页具有不同的 MediaBox 和更小的 CropBox，这是页级框不同，不是页数或文字覆盖统计冲突。fixture 的 bbox 使用所标页面 MediaBox 的左下原点 PDF 点坐标。pypdf / pdfplumber 的结果不是 PDFKit 兼容性证明；真正的 PDFKit 选词和设备回归仍待完成。

代表行文本、每行 bbox、选中 UTF-16 范围及坐标约定位于 `Tests/Fixtures/LayoutBlock-Samples.json`。该 JSON 当前由 `Tests/LayoutBlockContextBuilderTests.swift` 读取。IELTS 第 50 页样本只保留一段题干前缀，bbox 覆盖整行且不含圆圈题号，因此只验证基本几何与范围映射，不用于断言题号检测。

## 扫描页 OCR 参考图

`Tests/Fixtures/IELTS-context-strip.png` 是 IELTS PDF 第 10 页正文两行的独立裁剪图，尺寸 1056 × 105 px；由 300 dpi 页面渲染裁出，页面像素边界为左上原点 `(54, 690)–(1110, 795)`，对应 MediaBox 左下原点约 `[12.96, 577.2, 253.44, 25.2]` pt。裁剪图只含两行正文和边白，不含整页。

两行参考字符串由人根据扫描图转录，保存在 fixture 与测试中；不是 PDF 文字层，也不是 Vision 输出。`Tests/RealScanContextTests.swift` 将该图置入约 293.44 × 65.2 pt 的纯图像 PDF，调用现有 `OCRService.recognizeContextPage`，从实际识别的 `classroom` 建立选择、验证 `.layoutBlock` 和 `ContextualTranslationRequest.make`，并只打印 CER/WER 数值与行数、不输出识别全文、不设准确率阈值。该真实裁剪链路在 run `42363494350` 中通过，CER 0.019、WER 0.105、2 行；这是单张两行裁剪的 CI 证据，不代表整本 OCR 精度或真实 iPad 识别表现。

## 官方资料与运行 / 许可核查

下表记录截至 2026-11-07 能从官方文档或仓库核对到的事实。开源仓库许可证只覆盖仓库代码；预训练权重和数据集须另行核对其自身许可。

| 候选 | 已核实的能力、许可与运行条件 | 本轮状态 |
|---|---|---|
| [Apple attributed Translation API](https://developer.apple.com/documentation/translation/translationsession/translate%28_%3A%29-59zi2) | `translate(AttributedString)` 支持保留格式和自定义属性；当前项目代码有 `iOS 26.4` 可用性保护，并使用既有 Token ID attributes。实际语言包、候选译义、属性回传仍需真实设备验证。 | 复用已有路径；本轮不新增翻译服务。 |
| [Apple RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest) 与 [WWDC25 介绍](https://developer.apple.com/videos/play/wwdc2025/272/) | Apple 文档说明结构化观察可包含词、行、段落、表格和列表；WWDC25 介绍涵盖 iPad。 | 可作为本机结构识别备选；当前代码未调用。后续需对其文本与现有 canonical OCR 做精确对齐，再评估页框与性能。 |
| [PaddleOCR PP-StructureV3](https://www.paddleocr.ai/latest/en/version3.x/algorithm/PP-StructureV3/PP-StructureV3.html) | PaddleOCR 仓库代码为 Apache-2.0；官方安装文档把文档解析列为 `doc-parser` 可选组，需 Python 与已安装的推理引擎（如 PaddlePaddle、Transformers 或 ONNX Runtime），运行时还需模型权重。PaddleOCR 核心 Python 要求为 3.8+；部分可选组要求 3.9+。权重许可需逐模型核对。 | 候选参考，不在 iOS 工程中；无已验证的 iPad 转换产物、端侧性能或耗电数据。当前 bundled Python 未安装 `paddleocr` / `paddle`。 |
| [awesome-align](https://github.com/neulab/awesome-align) | 仓库许可为 BSD-3-Clause；README 要求安装依赖，项目使用 PyTorch 和 multilingual BERT checkpoint，checkpoint 可下载并缓存。依赖与权重许可须分别核对。 | 词对齐候选，不负责 PDF 版面结构；无本项目 iPad 打包或端侧实测。当前 bundled Python 未安装 `torch` / `awesome_align`。 |
| [SimAlign](https://github.com/cisnlp/simalign) | 仓库许可为 MIT；README 记录的旧测试环境是 Python 3.7、Transformers 3.1.0、Torch 1.5.0，并称可在 CPU 上运行。`setup.cfg` 列有 NumPy、Torch、SciPy、Transformers、regex、NetworkX、scikit-learn 等依赖。该 README 不是对现代或 iPad 环境的兼容性承诺。 | 词对齐研究候选；未接入、未安装、未在本项目设备上验证。 |

本次只在隔离的 bundled Python 环境检查了模块存在性：`pypdf` 与 `pdfplumber` 可用；PaddleOCR、PaddlePaddle、PyTorch、Transformers、SimAlign、awesome-align 均未安装。未下载模型、未运行在线 OCR，也未安装新依赖。

## 验证状态

- `Tests/LayoutBlockContextBuilderTests.swift` 使用 JSON 样本；`Tests/RealScanContextTests.swift` 的 IELTS 两行裁剪真实 Vision OCR 链路在最新 `test-ink` run `42367223532` 中通过，CER 0.019、WER 0.105、2 行。该数据只描述这一张裁剪图，不可外推为整书精度。
- 前一候选 `2418b0c` 的 [test-ink run 42363494350](https://github.com/lei11118/pdf-vocab/actions/runs/42363494350) 总体失败：276 项 unit/integration 中有 8 项断言失败（1 项服务测试仍用旧 fake 数据，7 项依赖 UIView 手工 accessibility 标识）；6 项既有 UI 测试通过。同 SHA 的 [build-ipa run 42363498841](https://github.com/lei11118/pdf-vocab/actions/runs/42363498841) 成功，IPA 元数据为 v0.72.0 / build 123、minimum iOS 26.0；ARM64、ZIP CRC 与 3 个 SQLite headers 检查通过。
- 中间提交 `eb728dc440ee65fefc9ae5d0b56cc3b322098a1e` 增加同屏展示与滚动的 XCUITest 覆盖；历史 [test-ink run 42365503411](https://github.com/lei11118/pdf-vocab/actions/runs/42365503411) 有 1 项 compact dictionary 的 AX 文本断言未通过（当时只检查 `value` 字符串）；后续改为合并 `value` 与 `label` 校验并在最新提交重跑通过，其余 276 项 unit/integration 与 6 项 UI 通过。同 SHA 的 [build-ipa run 42365515271](https://github.com/lei11118/pdf-vocab/actions/runs/42365515271) 成功，旧包大小 48,159,484 bytes，SHA-256 `1b94aa4ee6f81c086d5ddae71ef5693137c29b34130f26dd24a57df3b46afd41`。该中间结果已由以下提交重新验证。
- 最新提交 `440d08d9593c3e466707200a20a931e94d63d64a` 修正 AX 文本读取。[test-ink run 42367223532](https://github.com/lei11118/pdf-vocab/actions/runs/42367223532) 已通过：276 项 unit/integration + 7 项 UI，共 283 项，零失败；同 SHA 的 [build-ipa run 42367236564](https://github.com/lei11118/pdf-vocab/actions/runs/42367236564) 成功，IPA 大小 48,159,484 bytes，SHA-256 `84be36fe83031f27b62c46823a249807c23c254cc6ab6a3b21cd0e647c875364`。包元数据为 v0.72.0 / build 123、minimum iOS 26.0、ARM64，ZIP CRC 与 3 个 SQLite headers 检查通过。
- iPadOS 26.4+ Translation 行为、真实 iPad OCR 与选词精度仍待验证；数学识别、外部模型集成和 release acceptance 未完成。

## 参考链接

- [PaddleOCR Apache-2.0 LICENSE](https://github.com/PaddlePaddle/PaddleOCR/blob/main/LICENSE)
- [PaddleOCR 3.x 安装说明](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/installation.en.md)
- [PaddleOCR PP-StructureV3 用法](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/pipeline_usage/PP-StructureV3.en.md)
- [awesome-align BSD-3-Clause LICENSE](https://github.com/neulab/awesome-align/blob/master/LICENSE) 与 [依赖声明](https://github.com/neulab/awesome-align/blob/master/setup.py)
- [SimAlign MIT LICENSE](https://github.com/cisnlp/simalign/blob/master/LICENSE)、[README](https://github.com/cisnlp/simalign/blob/master/README.md) 与 [依赖声明](https://github.com/cisnlp/simalign/blob/master/setup.cfg)

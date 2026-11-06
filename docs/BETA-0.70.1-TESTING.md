# v0.70.1-beta 测试说明

版本：`0.70.1`（build `119`）

用途：内部测试版。CI 结果已记录；真机清单仍待实际设备验证。

## 本次改动

- 修复旧整句翻译路径在文本变化后没有可靠重启翻译任务、仍显示旧状态的问题。任务和视图状态按原文 UTF-8 字节区分。
- 增加独立的端侧整句译文 LRU 缓存，最多保留 32 条，缓存键包含原文精确字节及固定的 `en` → `zh-Hans`、Apple Translation Session backend 身份。
- 缓存不受语境阅读实验开关影响；只在翻译成功且译文非空、长度不超过 8192 个 UTF-16 单元时写入。翻译任务取消时不回调旧结果或失败。
- `SentenceTranslationState` 调用方接口保持不变。

## 实验开关

语境阅读实验开关 `contextReading.enabled` 默认关闭。数学和预取开关 `contextReading.mathEnabled`、`contextReading.prefetchEnabled` 也默认关闭；启用子开关仍要求语境阅读总开关开启。本次旧整句翻译缓存不读取这些开关。

## CI 回归范围

本版本必须运行 GitHub Actions `test-ink` 的完整配置：`unit_only=false`、`gesture_only=false`、`workspace_only=false`。工作流应执行 `PdfVocabTests` 与 `ReaderRouteUITests`，不能使用仅单元测试配置替代。另运行 `build-ipa` workflow_dispatch，并确认 IPA 由相同提交 SHA 构建。

| 检查项 | 结果 |
|---|---|
| 完整 `test-ink`（单元及 UI 回归） | [run 42159708324](https://github.com/lei11118/pdf-vocab/actions/runs/42159708324) 成功：187 个单元测试 + 5 个 UI 测试，共 192 项、0 失败 |
| `build-ipa` | [run 42159718867](https://github.com/lei11118/pdf-vocab/actions/runs/42159718867) 成功；与 `test-ink` 同源代码 SHA：`76f4b92b50536bc2c84c7e9cf7b2f816c3797bf0` |
| IPA SHA-256 | `E007C67BE977087D27208278CF928DECC5379CA974AF91D1B3D00B06C3A06018` |

## 真机回归清单

以下项目需要在真实 iPad 上逐项记录；模拟器通过不能代替真机检查。

- [ ] 原生文字 PDF：打开、选词、翻译并切换句子。
- [ ] 照片 PDF：打开扫描页，检查 OCR 选区与整句翻译。
- [ ] 双击与长按：分别检查选词/选句；点击 PDF 链接仍能导航。
- [ ] 悬浮释义：检查词性、中文释义及卡片中的词语选择。
- [ ] Apple Pencil 捏压：确认工具响应正常。
- [ ] 双层弧形工具盘：检查展开、选择工具及关闭行为。
- [ ] 尺子：检查双指操作、角度圈反馈及画布移动/缩放后的定位。
- [ ] 悬浮窗口：检查移动、缩放以及收起和展开。
- [ ] 多窗口：检查不同文档并存、切换和关闭后的状态。
- [ ] 安装目标语言包后在线翻译；断网后使用已安装语言包翻译。
- [ ] 未安装语言包或离线不可用时检查错误提示。
- [ ] 翻译过程中取消并快速切换多个句子，确认不会显示旧句结果或旧失败。

## 尚未完成的范围

- G3 语境阅读接入、GRDB 数据持久化和语言包引导尚未完成。
- G4 对齐工作尚未完成。
- G5–G7 数学功能及外部模型接入尚未完成。

本测试版仅记录本次整句翻译路径修复及其回归准备，不代表 G3–G7 全部完成。

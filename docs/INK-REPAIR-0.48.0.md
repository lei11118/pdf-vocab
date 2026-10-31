# v0.48.0 / build 91：墨迹跟随、笔刷与橡皮

本文件修正文档的中文编码问题，不替换或回退任何源码。后续版本详见 [v0.49.0 记录](INK-REPAIR-0.49.0.md)。

## 已交付改动

- MetalInkHost.swift：墨层挂到 PDF 文档坐标树；接入局部/整笔橡皮、撤销与保存。
- InkBrush.swift、InkMetalCanvasView.swift：独立笔刷参数，荧光笔最高 30% 不透明度，单笔先合并覆盖再合成；保留点按并缓存干墨。
- ReaderCoordinator.swift：传递真实工具种类和橡皮参数，避免选橡皮后继续写钢笔。
- InkRegressionTests.swift、project.yml：新增 GPU、坐标和擦除持久化回归，版本更新为 0.48.0 / 91。

## 已验证证据

代码提交 `95af894`。
[test-ink](https://github.com/lei11118/pdf-vocab/actions/runs/41191774690)：`Executed 9 tests, with 0 failures`、`TEST SUCCEEDED`。
[build-ipa](https://github.com/lei11118/pdf-vocab/actions/runs/41191775683)：成功。

安装包 `dist/v0.48.0-final/PdfVocab-unsigned.ipa`：9,040,659 字节。
ZIP 完整性、版本、Bundle ID、未签名 arm64 和内置词典检查通过。
SHA256：`448fc65bf1629a2636f5f1f7e12bbfdcecc394c5017c6e4cced5476851e103e0`。

## 未验证与边界

模拟器通过不代表真实 Pencil 手感、长时间稳定性和大文档性能已验收。局部橡皮为矢量切分；旧版误存为钢笔的笔迹不猜测转换为荧光笔。此版未接通自研套索、形状与 JSON 墨迹 PDF 导出。套索和形状已在后续 v0.49.0 范围内处理。

本轮使用 stdin 执行脚本，无本机临时脚本；测试数据由用例清理。保留安装包。

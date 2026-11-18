# iPad Pro M4 阅读与翻译验收

## 构建和模型

真机构建使用固定的 llama.cpp b12499 官方 XCFramework。模拟器构建先运行
`bash scripts/prepare_translation_runtime.sh`，从同一个源码提交生成两种 iOS 切片。CI 对模拟器产物使用单独缓存。

设备开发构建在「设置 → 语境阅读 → 翻译模型」中列出可下载的 Hy-MT2 GGUF。8 GB 档可评测 1.8B Q4 与 2-bit，16 GB 档还可评测 7B Q4。发布构建的可下载列表需根据设备实测结果放行。

Core ML 候选使用同源 1.8B 权重、4-bit 分块量化和带状态的 KV 缓存。导出环境使用 Python 3.12、Transformers 5.6.0、PyTorch 2.8、NumPy 1.26.4 和 Core ML Tools 9。

```sh
python scripts/qualify_m4_translation_coreml.py Hy-MT2-1.8B.mlpackage
xcrun coremlcompiler compile Hy-MT2-1.8B.mlpackage .
```

把编译产物放在设备开发构建的 `Documents/TranslationLab/Hy-MT2-1.8B.mlmodelc`。下载 1.8B Q4 GGUF 提供同源词表，然后在模型页选择 Metal、Core ML 自动分配或 Core ML CPU 与 Neural Engine。Core ML 导出脚本先比较原始模型与带状态包装器的预填充及后续预测。量化后的输出和资源使用仍需在设备上评测。

本地导出的完整模型为 1,008,933,858 字节。检查了模型格式、两个状态缓存、输入输出及 225 个分块解压算子。Linux 能完成导出与格式检查，实际 Core ML 推理和功耗仍需实体 iPad。

原始权重的七条桌面试译均未通过当前严格输出格式检查。部分结果翻译了整句，另有结果在要求河岸的选区中误译为「银行」。四条选区另试了括号标注和短释义提示，仍出现错义或标注丢失。下载候选保留在测试入口。

## 设备记录

- 使用 `Tests/Fixtures/ContextTranslation-M4.json` 的人工编写样本做首轮筛选。对可译项分别记正确、错误和缺失，语义等价的译法由双语评审判断。校验已展示译义准确率至少为 95%，可译项覆盖率至少为 85%。
- 在 8 GB 与 16 GB M4 上，以固定亮度和相同初始温度无线录制 Instruments Power Profiler。记录无翻译阅读基线，再轮换系统翻译与各本地后端。用 `LocalTranslation` 类别的 `Context gloss` signpost 标记推理区间。记录首次加载、热启动未命中、缓存命中、峰值内存、温升及每条正确译义的增量能耗。
- 在相同设备和负载上优先选达到质量标准且能耗距最低值不超过 10% 的最快 1.8B 配置。延迟相差不足 5% 时选能耗更低者。分别记录 7B 的专业译义增益。Core ML 的实际设备分配以性能报告和运行 trace 为准。
- 在阅读器分别验收原页、公式重绘、整体、分子或分母以及单符号高亮。截图需对应本次运行的提交。扫描页的模型输出及其原页几何分别验收。

## 扫描公式初筛

在 x86-64 CPU 上用 PaddleOCR 3.3.2、PaddlePaddle 3.2.2 运行 PP-FormulaNet_plus-S 官方权重。七个合成裁剪加一个 OpenStax 原页裁剪中，六个保持数学结构与符号。嵌套分式漏掉内层分母，偏导把小写 x 识别成大写 X。扫描模型保留为候选。测试处理的是预裁剪公式，整页定位和字符级选区还需独立验证。 [模型权重](https://huggingface.co/PaddlePaddle/PP-FormulaNet_plus-S/tree/3d46f557e3a1752f4bf81202395af3b5ecfadfd2)

## CI 与截图

候选提交 `07baf2d` 的未签名 IPA 构建成功。ZIP CRC、Info.plist 和 llama.framework 已在下载后检查。包大小为 56,917,877 字节，SHA-256 为 `7F1DCA5AFDF8B95BD911D23D8FF73B47123FC7E1829A664B33700468472EEB85`。 [构建与产物](https://github.com/lei11118/pdf-vocab/actions/runs/44256098915)

早期候选 `ed5be66` 的完整回归通过 341/342 个单元测试和 8/10 个 UI 测试。截图确认行内公式整体选区和重绘，同时复现分式初次长按与行内公式再次长按的失败。该结果对应手势修正前的版本。 [回归与截图](https://github.com/lei11118/pdf-vocab/actions/runs/44252271013)

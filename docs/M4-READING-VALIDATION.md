# iPad Pro M4 阅读与翻译验收

## 构建和模型

真机构建使用固定的 llama.cpp b12499 官方 XCFramework。模拟器构建先运行
`bash scripts/prepare_translation_runtime.sh`，从同一个源码提交生成两种 iOS 切片。CI 对模拟器产物使用单独缓存。

设备开发构建在「设置 → 语境阅读 → 翻译模型」中列出可下载的 Hy-MT2 GGUF。8 GB 档可评测 1.8B Q4 与 2-bit，16 GB 档还可评测 Hy-MT2 7B Q4 和 Qwen3.5 4B Q4。发布构建的可下载列表需根据设备实测结果放行。

Core ML 候选使用同源 1.8B 权重、4-bit 分块量化和带状态的 KV 缓存。导出环境使用 Python 3.12、Transformers 5.6.0、PyTorch 2.8、NumPy 1.26.4 和 Core ML Tools 9。

```sh
python scripts/qualify_m4_translation_coreml.py Hy-MT2-1.8B.mlpackage
xcrun coremlcompiler compile Hy-MT2-1.8B.mlpackage .
```

把编译产物放在设备开发构建的 `Documents/TranslationLab/Hy-MT2-1.8B.mlmodelc`。下载 1.8B Q4 GGUF 提供同源词表，然后在模型页选择 Metal、Core ML 自动分配或 Core ML CPU 与 Neural Engine。Core ML 导出脚本先比较原始模型与带状态包装器的预填充及后续预测。量化后的输出和资源使用仍需在设备上评测。

本地导出的完整模型为 1,008,933,858 字节。检查了模型格式、两个状态缓存、输入输出及 225 个分块解压算子。Linux 能完成导出与格式检查，实际 Core ML 推理和功耗仍需实体 iPad。

原始权重的七条桌面试译均未通过当前严格输出格式检查。部分结果翻译了整句，另有结果在要求河岸的选区中误译为「银行」。四条选区另试了括号标注和短释义提示，仍出现错义或标注丢失。下载候选保留在测试入口。

## 桌面 CPU 复测

使用与 App 同版本的 llama.cpp b12499，在 WSL x86-64 CPU 上固定 6 线程、1024 上下文、贪心解码。每组运行全部 32 条语境样本。新提示用括号标出精确选区，并用三个独立示例说明短译义和「无」。llama.cpp 的 JSON 约束只保证输出结构，不能保证抽取语义。

| 模型与提示 | 通过结构校验 | 与预设参考完全匹配 | 请求中位数 |
| --- | ---: | ---: | ---: |
| Hy-MT2 1.8B Q4_K_M，当前 App 提示，无词典提示 | 2/32 | 1/32 | 1.20 秒 |
| Hy-MT2 1.8B Q4_K_M，短提示与约束 | 32/32 | 25/32 | 1.11 秒 |
| Qwen3.5 0.8B Q4_0，短提示与约束 | 32/32 | 19/32 | 0.64 秒 |
| Qwen3.5 2B Q4_K_M，短提示与约束 | 32/32 | 20/32 | 1.27 秒 |
| Qwen3.5 4B Q4_K_M，短提示与约束 | 32/32 | 29/32 | 2.84 秒 |

完全匹配会漏计正确的同义词。逐条检查仍发现错误。Hy-MT2 把物理语境中的 work 译成「起作用」，把应显示「无」的从句连接词译成「似乎」。Qwen 0.8B 误解 hardly 的否定，Qwen 2B 把 strain 译为「张力」。Qwen 4B 正确处理了应变、拉应力和偏导数，仍会遗漏 hardly 的否定含义。4B 已加到 16 GB 档开发构建的 Metal 评测入口。这些桌面延迟仅用于本轮筛选。 [Qwen 原始权重与许可](https://huggingface.co/Qwen/Qwen3.5-0.8B) [0.8B 量化来源](https://huggingface.co/ggml-org/Qwen3.5-0.8B-GGUF/tree/004fd086eccea9f7cf867aa07ba328773beef81d) [2B 量化来源](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/tree/f6d5376be1edb4d416d56da11e5397a961aca8ae) [4B 量化来源](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/tree/e87f176479d0855a907a41277aca2f8ee7a09523)

## 设备记录

- 使用 `Tests/Fixtures/ContextTranslation-M4.json` 的人工编写样本做首轮筛选。对可译项分别记正确、错误和缺失，语义等价的译法由双语评审判断。校验已展示译义准确率至少为 95%，可译项覆盖率至少为 85%。
- 在 8 GB 与 16 GB M4 上，以固定亮度和相同初始温度无线录制 Instruments Power Profiler。记录无翻译阅读基线，再轮换系统翻译与各本地后端。用 `LocalTranslation` 类别的 `Context gloss` signpost 标记推理区间。记录首次加载、热启动未命中、缓存命中、峰值内存、温升及每条正确译义的增量能耗。
- 在相同设备和负载上优先选达到质量标准且能耗距最低值不超过 10% 的最快 1.8B 配置。延迟相差不足 5% 时选能耗更低者。分别记录 7B 的专业译义增益。Core ML 的实际设备分配以性能报告和运行 trace 为准。
- 在阅读器分别验收原页、公式重绘、整体、分子或分母以及单符号高亮。截图需对应本次运行的提交。扫描页的模型输出及其原页几何分别验收。

## 扫描公式初筛

在 x86-64 CPU 上用 PaddleOCR 3.3.2、PaddlePaddle 3.2.2 运行 PP-FormulaNet_plus-S 官方权重。七个合成裁剪加一个 OpenStax 原页裁剪中，六个保持数学结构与符号。嵌套分式漏掉内层分母，偏导把小写 x 识别成大写 X。扫描模型保留为候选。测试处理的是预裁剪公式，整页定位和字符级选区还需独立验证。 [模型权重](https://huggingface.co/PaddlePaddle/PP-FormulaNet_plus-S/tree/3d46f557e3a1752f4bf81202395af3b5ecfadfd2)

另试加白边、放大、紧裁剪与二值化。分割嵌套分式的原图可恢复分子 `\frac{73}{9}`，分母依旧被识别成大写 X。偏导在各变体中也出现 X。扫描公式的字符与结构仍无法可靠验收。

同一组裁剪也用官方 617 MB 的 PP-FormulaNet_plus-M 复测。M 档恢复了嵌套分式结构，但嵌套分式和偏导的 x 仍识别为 X，保持原结构与符号的样本仍为 6/8。桌面 CPU 请求中位数为 S 档 0.38 秒和 M 档 1.89 秒。 [M 档模型权重](https://huggingface.co/PaddlePaddle/PP-FormulaNet_plus-M/tree/712e6e2e4c313b1ea163be5c350127b82662c58d)

## CI 与截图

候选提交 `837ed5f` 的未签名 IPA 构建成功。下载后检查了产物与 IPA 的 ZIP CRC、Info.plist 和 llama.framework。版本为 0.73.0，构建 124，最低系统为 iPadOS 26.0。包大小为 56,918,585 字节，SHA-256 为 `2357CC401F594544FD5A093C111D7E86DC7FCB22B7C3A694E4A419D6425F6CBA`。 [构建与产物](https://github.com/lei11118/pdf-vocab/actions/runs/44264189778)

早期候选 `ed5be66` 的完整回归通过 341/342 个单元测试和 8/10 个 UI 测试。截图确认行内公式整体选区和重绘，同时复现分式初次长按与行内公式再次长按的失败。该结果对应手势修正前的版本。 [回归与截图](https://github.com/lei11118/pdf-vocab/actions/runs/44252271013)

提交 `4d38289` 的三项阅读器 UI 专项测试通过。人工核对了 “73 / 91” 的原 PDF 裁剪、重排分式与 LaTeX，以及再次长按分母中数字 “1” 的精确高亮。单元测试通过 343/344 项。剩余失败是上下行距更宽的 PDF 分式，其几何修正另行回归。 [UI 截图与测试](https://github.com/lei11118/pdf-vocab/actions/runs/44260111183) [单元测试](https://github.com/lei11118/pdf-vocab/actions/runs/44260122632)

修正宽行距分式后，`837ed5f` 的 344 项单元测试全部通过。同一提交的 UI 专项有两项通过，分式用例在前置的设置开关阶段停止。随后让分式用例以已启用数学功能的测试状态启动，独立验证长按选区。 [单元测试](https://github.com/lei11118/pdf-vocab/actions/runs/44264210082) [专项复测](https://github.com/lei11118/pdf-vocab/actions/runs/44311569350) [完整回归](https://github.com/lei11118/pdf-vocab/actions/runs/44311582087)

第一次分式专项的失败截图和可访问性树显示开关已在等待结束后变为目标值。测试现额外读取一次最终状态，避免再次点击已经成功的开关。 [开关复测](https://github.com/lei11118/pdf-vocab/actions/runs/44313592934)

`d2abadc` 的 3 项阅读器 UI 专项全部通过。实际查看了分式整体与单数字选区截图。全量任务中先通过 344 项单元测试与 3 项 UI，随后达到 30 分钟的作业上限。全量作业上限调整到 45 分钟后已重新运行。 [截图与专项结果](https://github.com/lei11118/pdf-vocab/actions/runs/44311569350) [延长时限后的全量回归](https://github.com/lei11118/pdf-vocab/actions/runs/44317275153)

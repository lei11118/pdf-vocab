# 第三方组件与许可证

## 0.50.0 离线知识图谱资源

- Open English WordNet 2025：[来源](https://en-word.net/downloads)，CC BY 4.0 及 Princeton WordNet License。以共享英文义项建立同近义关系，保留词性及英文释义作为连线依据。转换生成 `Resources/LexicalSources/lexical.sqlite`，属于数据格式转换及子集抽取。
- Colin Goldberg / morphemes：[来源](https://github.com/colingoldberg/morphemes)，Copyright (c) 2019 Colin Goldberg，MIT。仅使用来源明确列出的词例并核对词素位置；不将词形还原结果当作词根。
- 完整许可文本、来源 URL、原始文件 SHA-256 和统计见 `Resources/LexicalSources/`；可用 `scripts/build_lexical.py` 重建。上述来源作者不为本应用背书。
- `ink-material-atlas-v2.png` 为本次 AI 生成的石墨／蜡笔颗粒材质；矢量中心线仍是笔迹数据，材质只参与着色。

本仓库自身代码:MIT(见 [LICENSE](LICENSE))。

## 随 App 分发的第三方组件 / 数据

| 组件 | 用途 | 许可证 | 来源 |
|---|---|---|---|
| GRDB.swift | SQLite 访问(用户数据 + 离线词库) | MIT | https://github.com/groue/GRDB.swift |
| ZIPFoundation | zip 读写(.apkg 导出 / 数据备份) | MIT | https://github.com/weichsel/ZIPFoundation |
| ECDICT | 离线英语词库数据(构建期裁剪生成 SQLite,数据文件本身不入库) | MIT | https://github.com/skywind3000/ECDICT |

## 构建期工具(不随 App 分发)

| 工具 | 用途 | 许可证 |
|---|---|---|
| XcodeGen | 由 project.yml 生成 Xcode 工程 | MIT |
| genanki | .apkg 文件格式参考(仅参考实现,未引入代码) | MIT |

## 系统框架

PDFKit、PencilKit、Vision、NaturalLanguage、AVFoundation、Translation(可选)均为 Apple 系统框架,无需额外许可。

# 第三方组件与许可证

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

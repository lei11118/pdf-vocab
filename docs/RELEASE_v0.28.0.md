# v0.28.0 · PDF 手写全量重构

## 这一版修什么

四个真机问题的根因都不在"某个按钮没接上",而在三条管道各自散着:工具状态分散在会话/Provider/每页画布,跨页靠抬笔后的下标启发式,实时墨迹被困在单页画布内。本版按 Notability 逆向资料的"湿墨/干墨分离 + 页面布局唯一真相源"重做了这三条管道。

### 1. 工具退出后不记忆

- 新增 `PencilToolState` 作为唯一状态(全局 + 按书各一份 v2 JSON),补齐以前漏存的
  `shapeKind` / `useCustomEraser` / `rulerActive`。
- `stateRevision` + latest-wins 应用:不再出现"签名没变 → 一次都不套用"或"排队时被丢掉一次"。
- 进入文档、创建新页叠层、回到前台都会强制套用完整状态。

### 2. 两页之间笔画不连续

- 新增全局湿墨层 `PencilWetInkHost`(PDFView 的直接子视图)。书写过程中,
  常规笔越出当前页的那一段实时画在湿墨层上,不再被下一页的页视图遮住。
- 跨页切分改为按"本次动作的下标范围"批量处理;书法分段、形状多笔会一次全部搬到邻页。
- 切分保留 `creationDate` 与插值桥接点,两半在页缝处共享同一个点。

### 3. 形状选完不能立即转换

- 形状类型属于**同步模式状态**,选择后立刻写进所有页画布;只有 `canvas.tool` 延后到下一轮 runloop。
- 形状选择按书持久化。

### 4. 书法笔迹无法正常显现

- 书法提交改为**分段定宽** `PKStroke`:同一中心线切成若干短段,每段固定 `size`,
  所有段共享一个 `creationDate`。不再依赖 PencilKit 是否遵守逐点 `size`。
- 整笔橡皮按 `creationDate` 分组,一次擦掉整条书法;跨页切分对整组段生效。
- 书写过程中的预览与最终分段使用同一中心线几何。

## 兼容性

- 手写数据格式不变:仍是 `(docSha, page) → PKDrawing`(页面坐标 + `scale`)。
- 工具状态首次启动自动迁移 v0.26 快照与更早的逐键值;失败回退默认值,不阻塞进入文档。
- 无新增依赖、无网络请求、Bundle ID 不变。

## 真机验收

见 `docs/HANDOFF.md` §9.1 的 v0.28.0 四项。重点日志关键字:

- `pencil: state loaded rev=… scope=doc|global`
- `pencil: state applied rev=…`
- `pencil: wet begin/end`
- `pencil: overflow check`
- `pencil: calli segments=…`
- `pencil: undo push … pages=[…]`

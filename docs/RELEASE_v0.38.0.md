# 跃文 v0.38.0(build 76)

> 三个底层模块开始落地。本版先把 **Module 1(智能直尺)** 与 **Module 2(跨页切分器)** 接入并出包,Module 3(无限画布生词板)在下一版接界面。

## Module 1 — 智能物理直尺(已接入)

新增 `Sources/Reader/Pencil/SmartRulerView.swift`:

| 能力 | 实现 |
|---|---|
| 视图与手势 | 尺身是一个**视口坐标的窄条视图**(760×26),`UIPanGestureRecognizer` 拖动 + `UIRotationGestureRecognizer` 双指旋转,两者用 `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` 同时识别 |
| 角度吸附 | `SmartRulerView.calculateSnappedAngle(current:)` 吸附到 0/30/45/60/90/120/135/180°,阈值 ±3°,0° 与 180° 等价;吸附瞬间 `UIImpactFeedbackGenerator(style: .rigid)` |
| 沿尺绘图 | 抬笔后把所有采样点**投影到尺线**(不是简单拉直),所以任意角度都贴合;判定容差 18pt,短于 8pt 的一笔不动 |
| 位置语义 | 尺子在**视口坐标**里,滚动/缩放页面原地不动;只有"关闭再开启"才回到屏幕正中并归零角度 |
| 不抢笔 | 拖动/旋转只收 `direct`(手指)触摸,Pencil 落在尺子上仍然写字;`point(inside:)` 只命中尺身,尺外全部穿透 |

同时删掉了上一版那条固定的横线尺(`InkRulerOverlay.swift`),避免两套尺子并存。

**Pencil Pro 侧旋**:已查证公开 API 是 `UITouch.rollAngle`(iOS 17.5+,不支持侧旋的机型返回 0),`UIHoverGestureRecognizer` 上也有同名属性。映射方式 `SmartRulerView.normalizedAngle(rollAngle + azimuthAngle)` 直接喂给 `applyAngle`,与吸附共用同一归一化路径;本版先不做默认开启,避免挤压/悬停时尺子乱转 —— 需要的话下版加一个"用侧旋控制尺子角度"的开关。

## Module 2 — 跨页无缝切分器(已入库)

新增 `Sources/Reader/Pencil/CrossPageInkSplitter.swift`:**纯几何、无状态、可单测**。

- `splitStrokeAtBoundary(stroke:pageBoundaryY:)` → `Result<SplitResult, SplitError>`;
- 线性插值 `t = (boundary − a.y) / (b.y − a.y)`,位置/笔宽/压力/方位角/倾角/透明度/**时间偏移**全部同参数插值;
- 交点 y **吸附到边界**(`y = pageBoundaryY`)消除浮点误差,两段共享同一个点 → 接缝无断层;
- `bottom` 段统一 `y -= pageBoundaryY`;
- 三种错误:`emptyPath` / `noCrossing` / `degenerateSegment`(含除零与水平段贴边退化);
- 两段共享 `creationDate`,系统层面仍是"同一笔",整笔橡皮与跨页撤销依赖这一点。

线上路径仍走 `PencilOverlayProvider.settleOverflow`(它要按排布轴切分、还要用**两页真实页矩形**对齐),本类型作为规范实现与新路径的重构基础。

## Module 3 — 无限画布生词板(下一版)

代码已在上一轮给出(`FreeformCanvasLayout` + `VocabCardView` + `@Observable` 模型 + 防抖落库),接线需要:GRDB 迁移 v12 建 `vocab_board_position` 表、生词本入口、以及与现有 `VocabStore` 的连接。这一版没有一起进,是为了不把"新界面 + 新表 + 新手势"和尺子重写塞进同一个包 —— 出了问题不好定位。

## 安装与验收

`PdfVocab-unsigned.ipa`,AltStore / SideStore / Sideloadly 自签安装,Bundle ID 未变。

1. 开尺子:屏幕正中一条带刻度的尺子;用手指拖动它、双指旋转它;
2. 转到接近 0/30/45/60/90/120/135/180° 时会被吸住并给一次触觉;
3. **滚动页面、缩放**:尺子原地不动;
4. 关掉再打开:回到正中、角度归零;
5. 沿着尺子画一笔:墨迹会精确贴在尺线上(任意角度都是);
6. Pencil 落在尺子身上写字不应被尺子抢走(尺子只吃手指)。

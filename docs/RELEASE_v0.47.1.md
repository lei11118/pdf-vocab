# v0.47.1 — 输入路由重写:手写正常 + 手指滑动恢复原生

> build 89 · `com.lei11118.pdfvocab` · 未签名 IPA(自签侧载)

## 你报的两个症状

> 书写模式下这次修改手写功能消失,单指滑动无效

一句话根因:**画布在“猜”这一笔是笔还是手指,猜错就必然坏一边。**

0.47.0 里 `InkMetalCanvasView` 铺在 `PDFView` 上层,自己在 `hitTest` 里读
`event.allTouches` 判断触摸类型 —— 这个时机 UIKit 不保证可靠:

- 猜成“不是笔”→ 笔落到下层,画布收不到采样 → **手写功能消失**;
- 猜成“是笔”→ 手指也被这层吃掉,PDFView 收不到 → **单指滑不动**。

而且它还有第二个致命点:采样点必须落在 `clipRects` 里才落墨,
而 `clipRects` 只在 `refresh()` 里算 —— 一次没算出来就是**一点墨都不出,且不报错**。

## 改法:不再猜,把“接笔”和“接手势”彻底分开

1. **画布变成纯渲染层**
   `isUserInteractionEnabled = false`,删掉全部 `touchesBegan/Moved/Ended` 与 `hitTest`。
   它再也不可能抢走任何触摸。

2. **新增 `InkPencilGrabRecognizer`(只接 Pencil 的手势识别器)**
   挂在 `PDFView` 上,`allowedTouchTypes = [.pencil]`:
   - **手指的触摸根本不会进它**,PDFView 的原生滚动 / 捏合 / 长按选词一行不改;
   - 它永远停在 `.possible`,从不识别成功 → **不取消任何系统手势**,也不影响 PDFKit;
   - 它拿到的仍是真实 `UITouch`(force / 倾角 / 方位角 / coalesced / predicted 全在),
     所以压感和速度笔宽一点都不丢;
   - 挂点是 PDFView 而不是页面视图,所以笔落在页面视图上也能收到 —— 不依赖命中目标。

3. **`MetalInkHost.hitTest` 恒为 nil**
   墨迹层彻底不参与触摸分发。

4. **裁剪兜底**
   页矩形还没算出来时退化为“按画布范围裁剪”,并写一行
   `metal ink: no clip rects yet canvas=WxH`。**宁可暂时不裁,也不能一个字都不出。**

## 真机验收(顺序别换,一步一确认)

1. 进书写模式,**单指上下滑** → 页面顺滑滚动(和选词模式手感一致);
2. 双指捏合 → 缩放正常;
3. Pencil 写一笔 → 立刻出墨,笔迹圆润连续;
4. 停手 → 墨留在原处;
5. 滑动页面 → 墨**跟着纸**一起动;
6. 页边书写 → 页外不出现墨点;
7. 两指轻点撤销 / 三指轻点重做;
8. 切回选词模式 → 长按选词、拖柄、悬停查词正常。

## 日志对照(出问题时看这四行)

```
metal ink: pencil grab installed
metal ink: attached size=WxH
metal ink: scroll observed zoom=1.00
metal ink: refresh pages=N strokes=M
```

- 缺 `pencil grab installed` → 抓笔识别器没挂上;
- 缺 `scroll observed` → 没找到 PDFView 内部滚动视图,滚动时墨会不跟手;
- 写了字但没有 `metal ink: commit strokes=N` → 采样没进来(把日志发我);
- 出现 `no clip rects yet` → 页矩形没算出来(会用画布兜底,能写但不裁页边)。

## 仍待办

橡皮 / 荧光 / 蜡笔 / 形状 / 激光笔的工具语义、直尺吸附都还在旧 PencilKit 路径上,
自研引擎目前只吃钢笔;生词本整页重构、OCR 精度档未动。

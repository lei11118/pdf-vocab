import SwiftUI
import PDFKit
import PencilKit
import Vision

enum GraphCapture {
    struct Result {
        var image: UIImage
        var normalized: CGRect
        var words: [GraphWord]
        var page: Int
    }
    @MainActor static func render(view: PDFView, rect: CGRect, docId: String, ink: PencilInkStore) throws -> Result {
        guard let page = view.page(for: CGPoint(x: rect.midX,y:rect.midY), nearest: false), let document = view.document else { throw CocoaError(.fileReadCorruptFile) }
        let pageBounds = page.bounds(for: .cropBox)
        let selected = view.convert(rect, to: page).intersection(pageBounds)
        guard selected.width > 2, selected.height > 2 else { throw CocoaError(.fileReadCorruptFile) }
        let index = document.index(for: page)
        let scale: CGFloat = max(2, min(4, view.scaleFactor))
        let displayPage = view.convert(pageBounds,from:page)
        let displayCrop = view.convert(selected,from:page)
        let pixelsPerViewPoint = scale / max(0.01, view.scaleFactor)
        let fullSize = CGSize(width:displayPage.width*pixelsPerViewPoint,height:displayPage.height*pixelsPerViewPoint)
        let crop = CGRect(x:(displayCrop.minX-displayPage.minX)*pixelsPerViewPoint,y:(displayCrop.minY-displayPage.minY)*pixelsPerViewPoint,width:displayCrop.width*pixelsPerViewPoint,height:displayCrop.height*pixelsPerViewPoint)
        func pixel(_ point: CGPoint) -> CGPoint {
            let p = view.convert(point,from:page)
            return CGPoint(x:(p.x-displayPage.minX)*pixelsPerViewPoint,y:(p.y-displayPage.minY)*pixelsPerViewPoint)
        }
        let origin = pixel(CGPoint(x:pageBounds.minX,y:pageBounds.maxY))
        let axisX = pixel(CGPoint(x:pageBounds.minX+1,y:pageBounds.maxY))
        let axisY = pixel(CGPoint(x:pageBounds.minX,y:pageBounds.maxY-1))
        let inkTransform = CGAffineTransform(a:axisX.x-origin.x,b:axisX.y-origin.y,c:axisY.x-origin.x,d:axisY.y-origin.y,tx:origin.x,ty:origin.y)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let base = page.thumbnail(of: fullSize, for: .cropBox)
        let image = UIGraphicsImageRenderer(size: crop.size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin:.zero,size:crop.size))
            context.cgContext.translateBy(x:-crop.minX,y:-crop.minY)
            base.draw(in:CGRect(origin:.zero,size:fullSize))
            context.cgContext.saveGState()
            context.cgContext.concatenate(inkTransform)
            if let record = ink.drawing(docSha:docId,page:index) {
                if let drawing = InkPage.decode(record.data) {
                    InkPDFRendering.draw(drawing,in:context.cgContext,pageSize:pageBounds.size,scale:1)
                } else if var drawing = try? PKDrawing(data:record.data) {
                    drawing.transform(using:CGAffineTransform(scaleX:1/max(1,record.scale),y:1/max(1,record.scale)))
                    drawing.image(from:CGRect(origin:.zero,size:pageBounds.size),scale:scale).draw(in:CGRect(origin:.zero,size:pageBounds.size))
                }
            }
            context.cgContext.restoreGState()
        }
        var words: [GraphWord] = [], seen = Set<String>(), visited = IndexSet()
        // Go through the same exact glyph adapter as page selection, including
        // repaired PDF advances and internal artificial word spaces.
        let text = (page.string ?? "") as NSString
        for i in 0..<text.length {
            if visited.contains(i) { continue }
            let char = page.selection(for:NSRange(location:i,length:1))?.bounds(for:page) ?? .null
            guard char.intersects(selected), let word = SelectionGeometry.initialWord(on:page,at:CGPoint(x:char.midX,y:char.midY),tolerance:0) else { continue }
            let key = SelectionGeometry.identity(for:word)
            guard seen.insert(key).inserted else { continue }
            for n in 0..<word.numberOfTextRanges(on:page) {
                if let range = Range(word.range(at:n,on:page)) { visited.insert(integersIn:range) }
            }
            let box = SelectionGeometry.placedBounds(of:word,on:page).intersection(selected)
            guard box.width > 0,box.height > 0 else { continue }
            let displayBox = view.convert(box,from:page)
            words.append(GraphWord(text:SelectionGeometry.lookupText(for:word),rect:CGRect(x:(displayBox.minX-displayCrop.minX)/displayCrop.width,y:(displayBox.minY-displayCrop.minY)/displayCrop.height,width:displayBox.width/displayCrop.width,height:displayBox.height/displayCrop.height)))
        }
        return Result(image:image,normalized:CGRect(x:(selected.minX-pageBounds.minX)/pageBounds.width,y:(selected.minY-pageBounds.minY)/pageBounds.height,width:selected.width/pageBounds.width,height:selected.height/pageBounds.height),words:words,page:index)
    }
    static func recognize(_ image: UIImage) throws -> [GraphWord] {
        guard let cg = image.cgImage else { throw CocoaError(.fileReadCorruptFile) }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage:cg).perform([request])
        var words: [GraphWord] = []
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first else { continue }
            text.string.enumerateSubstrings(in:text.string.startIndex..<text.string.endIndex,options:.byWords) { word, range, _, _ in
                guard let word,let box = try? text.boundingBox(for:range)?.boundingBox else { return }
                words.append(GraphWord(text:word,rect:CGRect(x:box.minX,y:1-box.maxY,width:box.width,height:box.height)))
            }
        }
        return words
    }
}

struct GraphCaptureOverlay: View {
    var onCancel: () -> Void
    var onConfirm: (CGRect) -> Void
    @State private var rect: CGRect?
    @State private var original: CGRect?
    @State private var drawing = false
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment:.topLeading) {
                Color.black.opacity(0.2).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:0).onChanged { value in
                        drawing = true
                        rect = CGRect(x:min(value.startLocation.x,value.location.x),y:min(value.startLocation.y,value.location.y),width:abs(value.location.x-value.startLocation.x),height:abs(value.location.y-value.startLocation.y)).intersection(CGRect(origin:.zero,size:geo.size))
                    }.onEnded { _ in drawing = false })
                if let rect,rect.width > 2,rect.height > 2 {
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .overlay(Rectangle().stroke(Color.accentColor,lineWidth:2))
                        .frame(width:rect.width,height:rect.height).position(x:rect.midX,y:rect.midY)
                        .gesture(DragGesture().onChanged { value in
                            if original == nil { original = rect }
                            let start = original!
                            self.rect = CGRect(x:min(max(0,start.minX+value.translation.width),geo.size.width-start.width),y:min(max(0,start.minY+value.translation.height),geo.size.height-start.height),width:start.width,height:start.height)
                        }.onEnded { _ in original = nil })
                    ForEach(0..<8,id:\.self) { index in
                        let x = index % 3 == 0 ? rect.minX : index % 3 == 1 ? rect.midX : rect.maxX
                        let y = index < 3 ? rect.minY : index < 5 ? rect.midY : rect.maxY
                        let actualX = index == 4 ? rect.maxX : index == 5 ? rect.minX : index == 6 ? rect.midX : index == 7 ? rect.maxX : x
                        Circle().fill(.white).overlay(Circle().stroke(Color.accentColor,lineWidth:2)).frame(width:12,height:12)
                            .frame(width:44,height:44).contentShape(Rectangle()).position(x:actualX,y:y)
                            .gesture(DragGesture().onChanged { value in
                                if original == nil { original = rect }
                                let start = original!
                                var x0=start.minX,x1=start.maxX,y0=start.minY,y1=start.maxY
                                if [0,3,5].contains(index) { x0=min(x1-10,max(0,start.minX+value.translation.width)) }
                                if [2,4,7].contains(index) { x1=max(x0+10,min(geo.size.width,start.maxX+value.translation.width)) }
                                if index < 3 { y0=min(y1-10,max(0,start.minY+value.translation.height)) }
                                if index > 4 { y1=max(y0+10,min(geo.size.height,start.maxY+value.translation.height)) }
                                self.rect=CGRect(x:x0,y:y0,width:x1-x0,height:y1-y0)
                            }.onEnded { _ in original = nil })
                    }
                }
                HStack {
                    Button("取消",role:.cancel,action:onCancel)
                    Spacer()
                    Text("框选内容加入知识图谱").font(.caption)
                    Spacer()
                    Button("确认") { if let rect { onConfirm(rect) } }.disabled(rect == nil || drawing)
                }.padding().background(.regularMaterial)
            }
        }
    }
}

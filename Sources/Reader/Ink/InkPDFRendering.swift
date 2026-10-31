import UIKit

/// Page-local vectors are clipped only at export. A transparency group makes
/// all geometry of one highlighter stroke contribute its opacity once.
enum InkPDFRendering {
    static func draw(_ page:InkPage,in context:CGContext,pageSize:CGSize,scale:CGFloat) {
        context.saveGState();context.scaleBy(x:scale,y:scale)
        context.clip(to:CGRect(origin:.zero,size:pageSize))
        for stroke in page.strokes {
            let pts=stroke.kind == .marker || stroke.kind == .custom ? stroke.points:InkBrush.smoothed(stroke.points)
            guard !pts.isEmpty else { continue }
            context.saveGState();context.setAlpha(CGFloat(stroke.a))
            context.beginTransparencyLayer(auxiliaryInfo:nil)
            context.setFillColor(UIColor(red:stroke.r,green:stroke.g,blue:stroke.b,alpha:1).cgColor)
            for (a,b) in zip(pts,pts.dropFirst()) {
                let dx=b.x-a.x,dy=b.y-a.y,length=hypot(dx,dy)
                guard length>0.000001 else { continue }
                let nx = -dy/length,ny=dx/length
                let path=CGMutablePath()
                path.move(to:CGPoint(x:a.x+nx*a.width/2,y:a.y+ny*a.width/2))
                path.addLine(to:CGPoint(x:a.x-nx*a.width/2,y:a.y-ny*a.width/2))
                path.addLine(to:CGPoint(x:b.x-nx*b.width/2,y:b.y-ny*b.width/2))
                path.addLine(to:CGPoint(x:b.x+nx*b.width/2,y:b.y+ny*b.width/2));path.closeSubpath()
                context.addPath(path);context.fillPath()
            }
            if stroke.kind != .marker || pts.count<3 && pts.first!.cg==pts.last!.cg {
                for p in pts { context.fillEllipse(in:CGRect(x:p.x-p.width/2,y:p.y-p.width/2,width:p.width,height:p.width)) }
            }
            context.endTransparencyLayer();context.restoreGState()
        }
        context.restoreGState()
    }
}

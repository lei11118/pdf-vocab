import UIKit

/// One logical stroke can have page-local storage fragments without introducing
/// artificial endpoint caps. Geometry is intersected exactly at page boundaries.
enum InkContinuity {
    struct Piece { var page: Int; var stroke: InkStroke }
    static func mix(_ a: InkPoint,_ b: InkPoint,_ t: Double) -> InkPoint {
        InkPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t,width:a.width+(b.width-a.width)*t,
                 force:a.force+(b.force-a.force)*t,altitude:a.altitude+(b.altitude-a.altitude)*t,
                 azimuth:a.azimuth+(b.azimuth-a.azimuth)*t,time:a.time+(b.time-a.time)*t)
    }
    static func interval(_ a: CGPoint,_ b: CGPoint,in rect: CGRect) -> ClosedRange<Double>? {
        var lo=0.0,hi=1.0
        let dx=Double(b.x-a.x),dy=Double(b.y-a.y)
        let p=[-dx,dx,-dy,dy],q=[Double(a.x-rect.minX),Double(rect.maxX-a.x),Double(a.y-rect.minY),Double(rect.maxY-a.y)]
        for i in 0..<4 {
            if abs(p[i])<1e-12 { if q[i]<0 { return nil };continue }
            let t=q[i]/p[i]
            if p[i]<0 { lo=max(lo,t) } else { hi=min(hi,t) }
            if lo>hi { return nil }
        }
        return lo...hi
    }
    static func partition(_ input: InkStroke, boxes: [Int:CGRect], maps: [Int:CGAffineTransform], startOrder: Int=0) -> [Piece] {
        guard input.points.count>1 else { return [] }
        var source=input;source.strokeID=input.strokeID ?? UUID()
        var result:[Piece]=[]
        var current:Int?;var run:[InkPoint]=[]
        func flush() {
            guard let page=current, !run.isEmpty,let map=maps[page] else { run=[];return }
            var piece=source;let inverse=map.inverted(),scale=max(0.000001,hypot(map.a,map.b))
            piece.points=run.map { p in var q=p;let v=p.cg.applying(inverse);q.x=Double(v.x);q.y=Double(v.y);q.width/=Double(scale);return q }
            if piece.points.count==1 { piece.points.append(piece.points[0]) }
            piece.fragmentOrder=startOrder+result.count
            result.append(Piece(page:page,stroke:piece));run=[]
        }
        for (a,b) in zip(source.points,source.points.dropFirst()) {
            var hits=boxes.keys.sorted().compactMap { page -> (Int,ClosedRange<Double>)? in
                guard let r=interval(a.cg,b.cg,in:boxes[page]!) else { return nil }
                if hypot(a.x-b.x,a.y-b.y)>1e-9 && r.upperBound-r.lowerBound<1e-9 { return nil }
                return (page,r)
            }.sorted { $0.1.lowerBound == $1.1.lowerBound ? $0.0<$1.0 : $0.1.lowerBound<$1.1.lowerBound }
            // A tap exactly on a shared border belongs to one page only.
            if hypot(a.x-b.x,a.y-b.y)<1e-9 { hits=Array(hits.prefix(1)) }
            for (page,r) in hits {
                let first=mix(a,b,r.lowerBound),last=mix(a,b,r.upperBound)
                if current != page || run.last.map({ hypot($0.x-first.x,$0.y-first.y)>0.01 }) == true { flush();current=page }
                if run.isEmpty { run.append(first) };run.append(last)
            }
            if hits.isEmpty { flush();current=nil }
        }
        flush();return result
    }
    static func joined(_ items: [InkRenderItem]) -> [InkRenderItem] {
        var groups:[UUID:[(Int,InkRenderItem)]]=[:];var order:[UUID]=[]
        for (i,item) in items.enumerated() {
            let id=item.stroke.strokeID ?? UUID()
            if groups[id]==nil { order.append(id) };groups[id,default:[]].append((i,item))
        }
        var result:[InkRenderItem]=[]
        for id in order {
            let entries=groups[id]!.sorted { ($0.1.stroke.fragmentOrder ?? 0,$0.0)<($1.1.stroke.fragmentOrder ?? 0,$1.0) }
            var current:InkRenderItem?
            for (_,entry) in entries {
                if var previous=current,let a=previous.stroke.points.last,let b=entry.stroke.points.first,
                   hypot(a.x-b.x,a.y-b.y)<0.05 {
                    previous.stroke.points.append(contentsOf:entry.stroke.points.dropFirst());previous.clip=previous.clip.union(entry.clip);current=previous
                } else { if let current { result.append(current) };current=entry }
            }
            if let current { result.append(current) }
        }
        return result
    }
}

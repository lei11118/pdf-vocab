import CoreGraphics
import Foundation

/// Bounded spring dynamics in graph coordinates; camera scale never affects mass.
enum VocabGraphPhysics {
    @discardableResult
    static func step(positions:inout [Int64:CGPoint],velocities:inout [Int64:CGVector],edges:[VocabGraphEdge],pinned:Set<Int64>,sizes:[Int64:CGSize]=[:],dt:CGFloat=1/30)->CGFloat {
        let ids=positions.keys.sorted(),h=max(0.001,min(1/30,dt))
        var forces=Dictionary(uniqueKeysWithValues:ids.map { ($0,CGVector.zero) })
        for i in ids.indices {
            for j in ids.indices where j>i {
                let a=positions[ids[i]]!,b=positions[ids[j]]!
                var dx=a.x-b.x,dy=a.y-b.y
                if abs(dx)+abs(dy)<0.001 { dx=1;dy=0.5 }
                let distance=max(1,hypot(dx,dy)),strength=min(1500,900000/(distance*distance))+max(0,85-distance)*9
                let x=dx/distance*strength,y=dy/distance*strength
                forces[ids[i]]!.dx+=x;forces[ids[i]]!.dy+=y
                forces[ids[j]]!.dx-=x;forces[ids[j]]!.dy-=y
            }
        }
        // Multiple lexical evidences between the same pair form one spring.
        var seen=Set<String>()
        for edge in edges {
            let key="\(min(edge.a,edge.b)):\(max(edge.a,edge.b))"
            guard seen.insert(key).inserted,let a=positions[edge.a],let b=positions[edge.b] else { continue }
            let dx=b.x-a.x,dy=b.y-a.y,d=max(1,hypot(dx,dy)),strength=(d-150)*2
            forces[edge.a]!.dx+=dx/d*strength;forces[edge.a]!.dy+=dy/d*strength
            forces[edge.b]!.dx-=dx/d*strength;forces[edge.b]!.dy-=dy/d*strength
        }
        var energy:CGFloat=0
        for id in ids {
            guard !pinned.contains(id) else { velocities[id] = .zero;continue }
            let f=forces[id]!,old=velocities[id] ?? .zero,p=positions[id]!
            let damping=pow(CGFloat(0.86),h*30)
            var v=CGVector(dx:(old.dx+(f.dx-p.x*0.025)*h)*damping,dy:(old.dy+(f.dy-p.y*0.025)*h)*damping)
            let speed=hypot(v.dx,v.dy)
            if speed>600 { v.dx*=600/speed;v.dy*=600/speed }
            guard v.dx.isFinite,v.dy.isFinite else { velocities[id] = .zero;continue }
            velocities[id]=v;positions[id]=CGPoint(x:max(-10000,min(10000,p.x+v.dx*h)),y:max(-10000,min(10000,p.y+v.dy*h)))
            energy=max(energy,hypot(v.dx,v.dy))
        }
        resolveCollisions(positions:&positions,velocities:&velocities,pinned:pinned,sizes:sizes)
        return energy
    }
    /// Hard separation of the full label footprint, after force integration.
    /// A pinned node is placed first; later nodes never displace it.
    static func resolveCollisions(positions:inout [Int64:CGPoint],velocities:inout [Int64:CGVector],pinned:Set<Int64>,sizes:[Int64:CGSize]=[:]) {
        let ids=positions.keys.sorted { a,b in
            if pinned.contains(a) != pinned.contains(b) { return pinned.contains(a) }
            return a<b
        }
        var occupied:[CGRect]=[]
        for id in ids {
            guard var p=positions[id],p.x.isFinite,p.y.isFinite else { continue }
            let size=sizes[id] ?? CGSize(width:85,height:40)
            func box(_ q:CGPoint)->CGRect {
                CGRect(x:q.x-size.width/2-4,y:q.y-size.height/2-4,width:size.width+8,height:size.height+8)
            }
            if !pinned.contains(id) {
                let original=p
                // Candidate boundary positions give a finite, deterministic free
                // position even when many saved nodes start at exactly one point.
                if occupied.contains(where:{$0.intersects(box(p))}) {
                    var candidates:[CGPoint]=[]
                    let hw=size.width/2+4,hh=size.height/2+4
                    for r in occupied {
                        candidates.append(CGPoint(x:r.maxX+hw+0.01,y:original.y))
                        candidates.append(CGPoint(x:r.minX-hw-0.01,y:original.y))
                        candidates.append(CGPoint(x:original.x,y:r.maxY+hh+0.01))
                        candidates.append(CGPoint(x:original.x,y:r.minY-hh-0.01))
                    }
                    candidates.sort { hypot($0.x-original.x,$0.y-original.y)<hypot($1.x-original.x,$1.y-original.y) }
                    if let free=candidates.first(where:{ q in !occupied.contains(where:{$0.intersects(box(q))}) }) { p=free }
                    positions[id]=p
                    // Remove velocity into a contact, preserving tangential glide.
                    var v=velocities[id] ?? .zero
                    if abs(p.x-original.x)>0.001 { v.dx=0 }
                    if abs(p.y-original.y)>0.001 { v.dy=0 }
                    velocities[id]=v
                }
            }
            occupied.append(box(p))
        }
    }

}

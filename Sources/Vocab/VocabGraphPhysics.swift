import CoreGraphics

/// Bounded spring dynamics in graph coordinates; camera scale never affects mass.
enum VocabGraphPhysics {
    @discardableResult
    static func step(positions:inout [Int64:CGPoint],velocities:inout [Int64:CGVector],edges:[VocabGraphEdge],pinned:Set<Int64>,dt:CGFloat=1/30)->CGFloat {
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
        return energy
    }
}

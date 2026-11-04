import SwiftUI

/// Grid coordinates use the same canvas origin and zoom as the nodes. At low
/// zoom levels skip minor divisions instead of drawing thousands of lines.
enum GraphGridLayout {
    static func spacing(zoom:CGFloat) -> CGFloat {
        guard zoom.isFinite,zoom > 0 else { return 32 }
        var value = 32*zoom
        while value < 20 { value *= 2 }
        while value > 80 { value /= 2 }
        return value
    }
    static func lines(length:CGFloat,offset:CGFloat,spacing:CGFloat) -> [CGFloat] {
        guard length > 0,offset.isFinite,spacing.isFinite,spacing > 0 else { return [] }
        let start = offset-floor(offset/spacing)*spacing
        return stride(from:start,through:length,by:spacing).map { $0 }
    }
}

struct GraphGridBackground: View {
    let offset:CGPoint
    let zoom:CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    var body:some View {
        Canvas { context,size in
            let spacing = GraphGridLayout.spacing(zoom:zoom)
            var path = Path()
            for x in GraphGridLayout.lines(length:size.width,offset:offset.x,spacing:spacing) {
                path.move(to:CGPoint(x:x,y:0)); path.addLine(to:CGPoint(x:x,y:size.height))
            }
            for y in GraphGridLayout.lines(length:size.height,offset:offset.y,spacing:spacing) {
                path.move(to:CGPoint(x:0,y:y)); path.addLine(to:CGPoint(x:size.width,y:y))
            }
            context.stroke(path,with:.color(DS.accent.opacity(contrast == .increased ? 0.25 : 0.10)),lineWidth:0.5)
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
import Combine
import PDFKit
import SwiftUI
import UIKit

enum HumanReadingAuditFixture {
    private static let pageBounds = CGRect(x: 0, y: 0, width: 600, height: 800)

    static func importFixtures(into store: DocumentStore) throws {
        UserDefaults.standard.set(false, forKey: FeatureFlags.contextReadingEnabledKey)
        UserDefaults.standard.set(false, forKey: "restoreWritingState")
        UserDefaults.standard.set("vertical", forKey: "readerLayoutMode")
        for key in ["readerCardX", "readerCardY", "readerCardW", "readerCardH"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for axis in ["X", "Y", "W", "H"] {
            UserDefaults.standard.removeObject(forKey: "readerWindow.全文搜索.\(axis)")
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
        if ProcessInfo.processInfo.arguments.contains("--human-reading-audit-piecewise") {
            let url = temporaryDirectory.appendingPathComponent("Piecewise-audit.pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            try piecewisePDF().write(to: url, options: .atomic)
            _ = try store.importFile(from: url)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--human-reading-audit-schrodinger") {
            for raster in [false, true] {
                let url = temporaryDirectory.appendingPathComponent(
                    raster ? "Schrodinger-audit-raster.pdf" : "Schrodinger-audit-native.pdf")
                defer { try? FileManager.default.removeItem(at: url) }
                try schrodingerPDF(raster: raster).write(to: url, options: .atomic)
                _ = try store.importFile(from: url)
            }
            return
        }
        let nativeURL = temporaryDirectory.appendingPathComponent("Human-reading-audit-text.pdf")
        let scanURL = temporaryDirectory.appendingPathComponent("Human-reading-audit-scan.pdf")
        defer {
            try? FileManager.default.removeItem(at: nativeURL)
            try? FileManager.default.removeItem(at: scanURL)
        }

        try nativePDF().write(to: nativeURL, options: .atomic)
        try scanPDF().write(to: scanURL, options: .atomic)
        _ = try store.importFile(from: nativeURL)
        _ = try store.importFile(from: scanURL)
    }

    static let piecewisePageRegion = CGRect(x: 120, y: 417, width: 250, height: 70)

    static func piecewisePDF() -> Data {
        UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            context.beginPage()
            func draw(_ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 24) {
                let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
                (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font])
            }
            draw("f(x)=", 140, 335)
            draw("⎧", 217, 314)
            draw("⎨", 217, 334)
            draw("⎩", 217, 354)
            draw("3x+1", 237, 318)
            draw("x≥2", 322, 318)
            draw("x", 237, 350)
            draw("2", 251, 345, size: 17)
            draw("x<2", 322, 350)
        }
    }

    static func nativePDF() -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        let text = renderer.pdfData { context in
            let font = UIFont.systemFont(ofSize: 34, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            context.beginPage()
            ("function relates input to output." as NSString).draw(at: CGPoint(x: 54, y: 116), withAttributes: attributes)
            ("classroom" as NSString).draw(at: CGPoint(x: 54, y: 224), withAttributes: attributes)
            ("E=mc²" as NSString).draw(at: CGPoint(x: 54, y: 338), withAttributes: attributes)
            ("α + β = γ" as NSString).draw(at: CGPoint(x: 54, y: 452), withAttributes: attributes)
            // Keep both compact text rows close to a real stroked rule in an isolated page area.
            ("73" as NSString).draw(at: CGPoint(x: 394, y: 544), withAttributes: attributes)
            ("91" as NSString).draw(at: CGPoint(x: 394, y: 592), withAttributes: attributes)
            context.cgContext.saveGState()
            context.cgContext.setStrokeColor(UIColor.black.cgColor)
            context.cgContext.setLineWidth(1.2)
            context.cgContext.move(to: CGPoint(x: 376, y: 588))
            context.cgContext.addLine(to: CGPoint(x: 452, y: 588))
            context.cgContext.strokePath()
            context.cgContext.restoreGState()
            context.beginPage()
            ("Internal link destination" as NSString).draw(at: CGPoint(x: 54, y: 116), withAttributes: attributes)
            ("Second page remains readable" as NSString).draw(at: CGPoint(x: 54, y: 224), withAttributes: attributes)
        }
        guard let document = PDFDocument(data: text),
              let source = document.page(at: 0),
              let destination = document.page(at: 1) else { return text }

        let font = UIFont.systemFont(ofSize: 34, weight: .regular)
        let classroomWidth = ("classroom" as NSString).size(withAttributes: [.font: font]).width
        let classroomHeight = font.lineHeight
        let topOrigin = CGPoint(x: 54, y: 224)
        let annotationBounds = CGRect(x: topOrigin.x,
                                      y: pageBounds.maxY - topOrigin.y - classroomHeight,
                                      width: classroomWidth,
                                      height: classroomHeight)
        let link = PDFAnnotation(bounds: annotationBounds, forType: .link, withProperties: nil)
        let destinationPoint = CGPoint(x: pageBounds.minX, y: pageBounds.maxY - 116)
        link.action = PDFActionGoTo(destination: PDFDestination(page: destination, at: destinationPoint))
        source.addAnnotation(link)
        return document.dataRepresentation() ?? text
    }

    static func scanPDF() -> Data {
        let imageSize = CGSize(width: 1500, height: 2000)
        let image = UIGraphicsImageRenderer(size: imageSize).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: imageSize))
            let font = UIFont.systemFont(ofSize: 94, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            ("OCR classroom marker" as NSString).draw(at: CGPoint(x: 120, y: 420), withAttributes: attributes)
            ("scan function" as NSString).draw(at: CGPoint(x: 120, y: 640), withAttributes: attributes)
            ("This page is raster" as NSString).draw(at: CGPoint(x: 120, y: 860), withAttributes: attributes)
            ("17 + 9 = 26" as NSString).draw(at: CGPoint(x: 120, y: 1250), withAttributes: attributes)
        }
        guard let bitmap = image.cgImage else { return Data() }
        return UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            context.beginPage()
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 0, y: pageBounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            context.cgContext.draw(bitmap, in: pageBounds)
            context.cgContext.restoreGState()
        }
    }

    /// Redrawn from OpenStax University Physics Vol. 3, equation 7.23.
    /// These are separate vector rule and text objects, independent of the recognition parser.
    static let schrodingerPageRegion = CGRect(x: 54, y: 465, width: 465, height: 58)

    static func schrodingerPDF(raster: Bool) -> Data {
        let region = schrodingerPageRegion
        let midline = pageBounds.maxY - region.midY
        func draw(_ context: CGContext) {
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 23)]
            var x = region.minX + 8
            func inline(_ text: String) {
                let string = text as NSString
                string.draw(at: CGPoint(x: x, y: midline - 15), withAttributes: attributes)
                x += string.size(withAttributes: attributes).width
            }
            func fraction(_ numerator: String, _ denominator: String) {
                let top = numerator as NSString
                let bottom = denominator as NSString
                let topWidth = top.size(withAttributes: attributes).width
                let bottomWidth = bottom.size(withAttributes: attributes).width
                let barWidth = max(topWidth, bottomWidth) + 4
                x += 3
                top.draw(at: CGPoint(x: x + (barWidth - topWidth) / 2, y: midline - 30),
                         withAttributes: attributes)
                bottom.draw(at: CGPoint(x: x + (barWidth - bottomWidth) / 2, y: midline + 2),
                            withAttributes: attributes)
                context.setStrokeColor(UIColor.black.cgColor)
                context.setLineWidth(1)
                context.move(to: CGPoint(x: x, y: midline))
                context.addLine(to: CGPoint(x: x + barWidth, y: midline))
                context.strokePath()
                x += barWidth + 3
            }
            inline("−")
            fraction("ℏ²", "2m")
            fraction("∂²Ψ(x,t)", "∂x²")
            inline("+ U(x,t)Ψ(x,t) = iℏ")
            fraction("∂Ψ(x,t)", "∂t")
        }
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        guard raster else {
            return renderer.pdfData { context in
                context.beginPage()
                draw(context.cgContext)
            }
        }
        let bitmap = UIGraphicsImageRenderer(size: pageBounds.size).image { context in
            UIColor.white.setFill()
            context.fill(pageBounds)
            draw(context.cgContext)
        }.cgImage
        guard let bitmap else { return Data() }
        return renderer.pdfData { context in
            context.beginPage()
            context.cgContext.translateBy(x: 0, y: pageBounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            context.cgContext.draw(bitmap, in: pageBounds)
        }
    }
}

struct HumanReadingAuditSnapshotView: View {
    let handle: ReaderHandle
    @State private var snapshot = "{}"
    private let refresh = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(snapshot)
            .font(.system(size: 1))
            .frame(width: 2, height: 2)
            .opacity(0.1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("human-reading-audit.snapshot")
            .accessibilityValue(snapshot)
            .accessibilityIdentifier("human-reading-audit.snapshot")
            .allowsHitTesting(false)
            .onReceive(refresh) { _ in
                guard let next = handle.coordinator?.humanReadingAuditSnapshotJSON(), next != snapshot else { return }
                snapshot = next
            }
    }
}
#endif

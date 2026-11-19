#if DEBUG
import Combine
import PDFKit
import SwiftUI
import UIKit

enum HumanReadingAuditFixture {
    private static let pageBounds = CGRect(x: 0, y: 0, width: 600, height: 800)

    static func importFixtures(into store: DocumentStore) throws {
        let startWithMathEnabled = ProcessInfo.processInfo.arguments.contains("--human-reading-audit-start-with-math")
        UserDefaults.standard.set(startWithMathEnabled, forKey: FeatureFlags.contextReadingEnabledKey)
        UserDefaults.standard.set(startWithMathEnabled, forKey: FeatureFlags.mathEnabledKey)
        UserDefaults.standard.set(false, forKey: "restoreWritingState")
        UserDefaults.standard.set("vertical", forKey: "readerLayoutMode")
        for key in ["readerCardX", "readerCardY", "readerCardW", "readerCardH"] {
            UserDefaults.standard.removeObject(forKey: key)
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
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

    private static func scanPDF() -> Data {
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
        return UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            context.beginPage()
            image.draw(in: pageBounds)
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

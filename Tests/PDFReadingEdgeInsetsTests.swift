import XCTest
import UIKit
import PDFKit
@testable import PdfVocab

@MainActor
final class PDFReadingEdgeInsetsTests: XCTestCase {
    func testEdgeInsetsAddOneHundredPointsOnceAndPreservePDFKitResets() {
        let scrollView = UIScrollView()
        let initial = UIEdgeInsets(top: 3, left: 7, bottom: 11, right: 13)
        scrollView.contentInset = initial

        for _ in 0..<4 {
            VocabPDFView.addReadingEdgeInsets(to: scrollView)
        }
        assertInsets(scrollView.contentInset,
                     equalTo: UIEdgeInsets(top: 103, left: 107, bottom: 111, right: 113))

        let resetByPDFKit = UIEdgeInsets(top: 2, left: 5, bottom: 9, right: 12)
        scrollView.contentInset = resetByPDFKit
        VocabPDFView.addReadingEdgeInsets(to: scrollView)
        assertInsets(scrollView.contentInset,
                     equalTo: UIEdgeInsets(top: 102, left: 105, bottom: 109, right: 112))

        VocabPDFView.removeReadingEdgeInsets(from: scrollView)
        assertInsets(scrollView.contentInset, equalTo: resetByPDFKit)
    }

    func testContinuousVerticalAndHorizontalLayoutsKeepFourSidedInsetsStable() throws {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 420)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            context.beginPage()
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let view = VocabPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = view
        window.frame = view.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageBreakMargins = .zero
        view.document = document
        view.layoutDocumentView()
        view.layoutIfNeeded()

        var verticalInsets: UIEdgeInsets?
        var horizontalInsets: UIEdgeInsets?
        for isHorizontal in [false, true, false, true] {
            view.displayDirection = isHorizontal ? .horizontal : .vertical
            view.pageBreakMargins = .zero
            view.layoutDocumentView()
            view.setNeedsLayout()
            view.layoutIfNeeded()

            let scrollView = try XCTUnwrap(view.documentView?.superview as? UIScrollView)
            let insets = scrollView.contentInset
            XCTAssertGreaterThanOrEqual(insets.top, VocabPDFView.readingEdgeInset)
            XCTAssertGreaterThanOrEqual(insets.left, VocabPDFView.readingEdgeInset)
            XCTAssertGreaterThanOrEqual(insets.bottom, VocabPDFView.readingEdgeInset)
            XCTAssertGreaterThanOrEqual(insets.right, VocabPDFView.readingEdgeInset)
            XCTAssertEqual(view.pageBreakMargins, .zero)

            if isHorizontal {
                if let previous = horizontalInsets { assertInsets(insets, equalTo: previous) }
                horizontalInsets = insets
            } else {
                if let previous = verticalInsets { assertInsets(insets, equalTo: previous) }
                verticalInsets = insets
            }
        }

        view.displayMode = .singlePage
        view.layoutDocumentView()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let singlePageScroll = try XCTUnwrap(view.documentView?.superview as? UIScrollView)
        XCTAssertLessThan(singlePageScroll.contentInset.top, VocabPDFView.readingEdgeInset,
                          "Leaving continuous layout restores the PDFKit baseline inset")
    }

    private func assertInsets(_ actual: UIEdgeInsets,
                              equalTo expected: UIEdgeInsets,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertEqual(actual.top, expected.top, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.left, expected.left, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.bottom, expected.bottom, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.right, expected.right, accuracy: 0.01, file: file, line: line)
    }
}

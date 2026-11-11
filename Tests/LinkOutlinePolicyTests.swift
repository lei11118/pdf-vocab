import XCTest
@testable import PdfVocab

final class LinkOutlinePolicyTests: XCTestCase {
    func testDensePagesSkipDecorativeOutlinesAndPreserveBoundedPageCounts() {
        XCTAssertFalse(LinkOutlineRenderingPolicy.shouldSkipOutlines(annotationCounts: [0, 512]))
        XCTAssertTrue(LinkOutlineRenderingPolicy.shouldSkipOutlines(annotationCounts: [12, 513]))
        XCTAssertTrue(LinkOutlineRenderingPolicy.shouldSkipOutlines(annotationCounts: [400, 400, 300]))
    }

    func testOutlineCountHasAHardUpperBound() {
        XCTAssertTrue(LinkOutlineRenderingPolicy.canAppendOutline(currentCount: 159))
        XCTAssertFalse(LinkOutlineRenderingPolicy.canAppendOutline(currentCount: 160))
        XCTAssertFalse(LinkOutlineRenderingPolicy.canAppendOutline(currentCount: 10_000))
    }
}

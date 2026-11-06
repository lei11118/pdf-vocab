import XCTest
import UIKit
@testable import PdfVocab

@MainActor
final class ReaderEdgeGaussianBlurTests: XCTestCase {
    func testLayoutAddsSoftFadeAfterBothSafeAreaBands() throws {
        let layout = ReaderEdgeGaussianBlurLayout(
            bounds: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            safeAreaInsets: UIEdgeInsets(top: 60, left: 0, bottom: 34, right: 0)
        )

        let top = try XCTUnwrap(layout.top)
        let bottom = try XCTUnwrap(layout.bottom)
        XCTAssertEqual(ReaderEdgeGaussianBlurLayout.fadeLength, 32)
        XCTAssertEqual(top.frame, CGRect(x: 0, y: 0, width: 1_000, height: 92))
        XCTAssertEqual(top.opaqueLength, 60)
        XCTAssertEqual(top.fadeLength, 32)
        XCTAssertEqual(bottom.frame, CGRect(x: 0, y: 734, width: 1_000, height: 66))
        XCTAssertEqual(bottom.opaqueLength, 34)
        XCTAssertEqual(bottom.fadeLength, 32)
        XCTAssertLessThanOrEqual(top.frame.maxY, bottom.frame.minY)
    }

    func testGradientMasksFadeTowardReaderContentWithoutTint() throws {
        let layout = ReaderEdgeGaussianBlurLayout(
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            safeAreaInsets: UIEdgeInsets(top: 60, left: 0, bottom: 34, right: 0)
        )
        let top = try XCTUnwrap(layout.top)
        let bottom = try XCTUnwrap(layout.bottom)
        let topMask = CAGradientLayer()
        let bottomMask = CAGradientLayer()
        top.configure(mask: topMask, size: top.frame.size)
        bottom.configure(mask: bottomMask, size: bottom.frame.size)

        XCTAssertEqual(topMask.startPoint, CGPoint(x: 0.5, y: 0))
        XCTAssertEqual(topMask.endPoint, CGPoint(x: 0.5, y: 1))
        XCTAssertEqual(topMask.locations ?? [],
                       [0, NSNumber(value: 60.0 / 92.0), 1])
        XCTAssertEqual(bottomMask.locations ?? [],
                       [0, NSNumber(value: 32.0 / 66.0), 1])
        XCTAssertEqual(alphaValues(topMask), [1, 1, 0])
        XCTAssertEqual(alphaValues(bottomMask), [0, 1, 1])
    }

    func testLayoutOmitsBandsWithoutSafeAreaInsetsAndClampsSmallBounds() {
        let empty = ReaderEdgeGaussianBlurLayout(
            bounds: CGRect(x: 0, y: 0, width: 320, height: 500),
            safeAreaInsets: .zero
        )
        XCTAssertNil(empty.top)
        XCTAssertNil(empty.bottom)

        let compact = ReaderEdgeGaussianBlurLayout(
            bounds: CGRect(x: 0, y: 0, width: 320, height: 100),
            safeAreaInsets: UIEdgeInsets(top: 45, left: 0, bottom: 45, right: 0)
        )
        let top = compact.top
        let bottom = compact.bottom
        XCTAssertLessThanOrEqual(top?.frame.maxY ?? 0, bottom?.frame.minY ?? 100)
        XCTAssertLessThanOrEqual(top?.frame.maxY ?? 0, 100)
        XCTAssertGreaterThanOrEqual(bottom?.frame.minY ?? 100, 0)
    }

    func testGaussianBlurClampsSolidInputWithoutBlackEdgePixels() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 18))
        let source = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 18))
        }
        let sourceCGImage = try XCTUnwrap(source.cgImage)
        let blurred = try XCTUnwrap(ReaderEdgeGaussianBlurProcessor.gaussianBlur(sourceCGImage))
        XCTAssertEqual(blurred.width, sourceCGImage.width)
        XCTAssertEqual(blurred.height, sourceCGImage.height)

        var pixels = [UInt8](repeating: 0, count: blurred.width * blurred.height * 4)
        let drewImage = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress,
                                          width: blurred.width,
                                          height: blurred.height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: blurred.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(blurred, in: CGRect(x: 0, y: 0,
                                             width: blurred.width, height: blurred.height))
            return true
        }
        XCTAssertTrue(drewImage)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertGreaterThanOrEqual(pixels[offset], 245, "Red channel at pixel \(offset / 4)")
            XCTAssertGreaterThanOrEqual(pixels[offset + 1], 245, "Green channel at pixel \(offset / 4)")
            XCTAssertGreaterThanOrEqual(pixels[offset + 2], 245, "Blue channel at pixel \(offset / 4)")
            XCTAssertEqual(pixels[offset + 3], 255, "Alpha at pixel \(offset / 4)")
        }
    }

    private func alphaValues(_ mask: CAGradientLayer) -> [CGFloat] {
        (mask.colors as? [CGColor] ?? []).map { $0.alpha }
    }
}

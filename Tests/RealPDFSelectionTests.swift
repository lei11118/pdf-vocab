import XCTest
import PDFKit
import UIKit
@testable import PdfVocab

@MainActor
final class GlyphSelectionTests: XCTestCase {
    func testOriginalOpenStaxWordHits() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "OpenStax-selection", withExtension: "pdf"))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let cases: [(Int, String, CGPoint)] = [
            (0, "Functions", CGPoint(x: 123.5795, y: 762.7960)),
            (0, "Functions", CGPoint(x: 167.4803, y: 409.7785)),
            (0, "Functions", CGPoint(x: 195.9708, y: 393.6285)),
            (0, "Trigonometric", CGPoint(x: 131.4312, y: 377.4785)),
            (0, "Functions", CGPoint(x: 183.4946, y: 377.4785)),
            (0, "Functions", CGPoint(x: 156.9352, y: 361.3285)),
            (0, "Functions", CGPoint(x: 245.6082, y: 345.1785)),
            (0, "magnitude", CGPoint(x: 146.9284, y: 281.0690)),
            (0, "magnitude", CGPoint(x: 250.4516, y: 281.0690)),
            (0, "magnitude", CGPoint(x: 119.8101, y: 269.6690)),
            (0, "magnitude", CGPoint(x: 120.7306, y: 258.2690)),
            (0, "magnitude", CGPoint(x: 343.6717, y: 258.2690)),
            (0, "magnitude", CGPoint(x: 488.5164, y: 246.8690)),
            (1, "functions", CGPoint(x: 459.7125, y: 655.3395)),
            (1, "functions", CGPoint(x: 365.2445, y: 627.7895)),
            (1, "functions", CGPoint(x: 147.8987, y: 590.0300)),
            (1, "motion", CGPoint(x: 184.6852, y: 578.6300)),
            (1, "motion", CGPoint(x: 429.8185, y: 578.6300)),
            (1, "electrical", CGPoint(x: 89.3660, y: 578.6300)),
            (1, "functions", CGPoint(x: 203.8964, y: 567.2300)),
            (1, "functions", CGPoint(x: 445.0150, y: 567.2300)),
            (1, "functions", CGPoint(x: 222.7602, y: 555.8300)),
            (1, "functions", CGPoint(x: 171.0259, y: 517.8300))
        ]
        for (index, expected, point) in cases {
            let page = try XCTUnwrap(document.page(at: index))
            let picked = SelectionGeometry.initialWord(on: page, at: point)
            let actual = picked.map { SelectionGeometry.lookupText(for: $0) } ?? "<nil>"
            let hint = page.characterIndex(at: point)
            print("REALPDF page=\(index) word=\(expected) actual=\(actual) count=\(page.numberOfCharacters) string=\((page.string as NSString?)?.length ?? 0) hint=\(hint)")
            if actual != expected, hint != NSNotFound {
                for i in max(0,hint-12)..<min(page.numberOfCharacters,hint+13) {
                    print("GLYPH \(i) native=\(page.characterBounds(at:i)) selection=\(page.selection(for:NSRange(location:i,length:1))?.bounds(for:page) ?? .null) text=\(page.selection(for:NSRange(location:i,length:1))?.string ?? "nil")")
                }
            }
            XCTAssertEqual(actual, expected, "page \(index) at \(point)")
        }
    }

    func testEveryVisibleCharacterHasAnAlignedSelection() throws {
        struct Hit: Decodable { let page: Int; let text: String; let point: [Double] }
        let bundle = Bundle(for:Self.self)
        let document = try XCTUnwrap(PDFDocument(url:try XCTUnwrap(bundle.url(forResource:"OpenStax-selection",withExtension:"pdf"))))
        let data = try Data(contentsOf:XCTUnwrap(bundle.url(forResource:"OpenStax-character-hits",withExtension:"json")))
        let hits = try JSONDecoder().decode([Hit].self,from:data)
        var failures: [String] = []
        for hit in hits {
            let page = try XCTUnwrap(document.page(at:hit.page)), point = CGPoint(x:hit.point[0],y:hit.point[1])
            let selection = SelectionGeometry.initialWord(on:page,at:point,tolerance:1)
                ?? SelectionGeometry.initialCharacter(on:page,at:point,tolerance:1)
            let actual = selection?.string?.precomposedStringWithCompatibilityMapping ?? "<nil>"
            let aligned = selection.map { SelectionGeometry.placedBounds(of:$0,on:page).insetBy(dx:-1,dy:-1).contains(point) } ?? false
            if !actual.contains(hit.text.precomposedStringWithCompatibilityMapping) || !aligned {
                failures.append("page=\(hit.page) char=\(hit.text) point=\(point) actual=\(actual) aligned=\(aligned)")
            }
        }
        print("ALL_CHARACTERS total=\(hits.count) failures=\(failures.count)")
        for value in failures.prefix(50) { print("CHARACTER_MISS \(value)") }
        XCTAssertTrue(failures.isEmpty,"\(failures.count)/\(hits.count) character failures: \(failures.prefix(8))")
    }

    func testEveryOriginalTextGlyphIsSelectable() throws {
        struct Hit: Decodable { let page: Int; let text: String; let points: [[Double]] }
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource:"OpenStax-selection",withExtension:"pdf"))
        let document = try XCTUnwrap(PDFDocument(url:url))
        let fixture = try XCTUnwrap(bundle.url(forResource:"OpenStax-glyph-hits",withExtension:"json"))
        let hits = try JSONDecoder().decode([Hit].self,from:Data(contentsOf:fixture))
        var geometry: [[String: Any]] = []
        for pi in 0..<document.pageCount {
            guard let page = document.page(at:pi), let text = page.string else { continue }
            let ns = text as NSString
            let attr = page.attributedString
            for i in 0..<ns.length {
                let r = page.selection(for:NSRange(location:i,length:1))?.bounds(for:page) ?? .null
                guard SelectionGeometry.isValid(r) else { continue }
                let font = i < (attr?.length ?? 0) ? attr?.attribute(.font,at:i,effectiveRange:nil) as? UIFont : nil
                let char = ns.substring(with:NSRange(location:i,length:1))
                geometry.append(["page":pi,"i":i,"ch":char,"rect":[r.minX,r.minY,r.width,r.height],
                    "font":font?.fontName ?? "nil","size":font?.pointSize ?? 0,
                    "advance":font.map { char.size(withAttributes:[.font:$0]).width } ?? 0])
            }
        }
        var placement: [[String:Any]] = []
        for pi in 0..<document.pageCount {
            guard let page = document.page(at:pi) else { continue }
            for glyph in PDFTextLayout.glyphs(on:page) {
                let r = glyph.rect
                placement.append(["page":pi,"ch":glyph.text,"rect":[r.minX,r.minY,r.width,r.height]])
            }
        }
        let placementAttachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:placement),uniformTypeIdentifier:"public.json")
        placementAttachment.name = "PDF-content-stream-placement"; placementAttachment.lifetime = .keepAlways; add(placementAttachment)
        var native: [[String:Any]] = []
        for pi in 0..<document.pageCount {
            guard let page = document.page(at:pi) else { continue }
            for i in 0..<page.numberOfCharacters {
                let r = page.characterBounds(at:i)
                guard SelectionGeometry.isValid(r) else { continue }
                native.append(["page":pi,"i":i,"rect":[r.minX,r.minY,r.width,r.height]])
            }
        }
        let nativeAttachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:native),uniformTypeIdentifier:"public.json")
        nativeAttachment.name = "PDFKit-native-glyph-bounds"; nativeAttachment.lifetime = .keepAlways; add(nativeAttachment)
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:geometry),uniformTypeIdentifier:"public.json")
        attachment.name = "OpenStax-PDFKit-glyphs"
        attachment.lifetime = .keepAlways
        add(attachment)
        var failures: [String] = [], total = 0
        for hit in hits {
            let page = try XCTUnwrap(document.page(at:hit.page))
            for (offset, coordinates) in hit.points.enumerated() {
                total += 1
                let point = CGPoint(x:coordinates[0],y:coordinates[1])
                let selection = SelectionGeometry.initialWord(on:page,at:point,tolerance:1)
                let actual = selection.map { SelectionGeometry.lookupText(for:$0) } ?? "<nil>"
                if actual != hit.text {
                    failures.append("page=\(hit.page) word=\(hit.text) glyph=\(offset) at=\(point) actual=\(actual)")
                }
            }
        }
        print("ALL_GLYPHS total=\(total) failures=\(failures.count)")
        for failure in failures.prefix(100) { print("GLYPH_MISS \(failure)") }
        XCTAssertTrue(failures.isEmpty,"\(failures.count)/\(total) glyph failures: \(failures.prefix(12))")
    }
}

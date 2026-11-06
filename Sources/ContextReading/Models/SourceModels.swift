import CryptoKit
import Foundation

/// A range measured in UTF-16 code units, matching PDFKit and NSString APIs.
struct UTF16Span: Hashable, Codable, Sendable {
    let location: Int
    let length: Int

    init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    init?(range: NSRange, in source: String) {
        guard range.location != NSNotFound else { return nil }
        let span = UTF16Span(location: range.location, length: range.length)
        guard span.nsRange(in: source) != nil else { return nil }
        self = span
    }

    init?(composedRange: NSRange, in source: String) {
        guard composedRange.location != NSNotFound else { return nil }
        let span = UTF16Span(location: composedRange.location, length: composedRange.length)
        guard span.composedCharacterRange(in: source) != nil else { return nil }
        self = span
    }

    var endExclusive: Int? {
        guard location >= 0, length >= 0 else { return nil }
        let (end, overflow) = location.addingReportingOverflow(length)
        return overflow ? nil : end
    }

    func nsRange(in source: String) -> NSRange? {
        let utf16Length = (source as NSString).length
        guard location >= 0, length >= 0,
              location <= utf16Length,
              length <= utf16Length - location else { return nil }
        let end = location + length
        guard Self.isUnicodeScalarBoundary(location, in: source),
              Self.isUnicodeScalarBoundary(end, in: source) else { return nil }
        return NSRange(location: location, length: length)
    }

    /// A stricter range for semantic tokens: neither edge may split an
    /// extended grapheme such as a combining sequence or ZWJ emoji.
    func composedCharacterRange(in source: String) -> NSRange? {
        guard let range = nsRange(in: source),
              Self.isComposedCharacterBoundary(location, in: source),
              Self.isComposedCharacterBoundary(location + length, in: source) else { return nil }
        return range
    }

    func substring(in source: String) -> String? {
        guard let range = nsRange(in: source) else { return nil }
        return (source as NSString).substring(with: range)
    }

    func intersects(_ other: UTF16Span) -> Bool {
        guard let end = endExclusive, let otherEnd = other.endExclusive else { return false }
        return location < otherEnd && other.location < end
    }

    private static func isUnicodeScalarBoundary(_ offset: Int, in source: String) -> Bool {
        let ns = source as NSString
        guard offset > 0, offset < ns.length else { return offset >= 0 && offset <= ns.length }
        let previous = ns.character(at: offset - 1)
        let next = ns.character(at: offset)
        let splitsSurrogatePair = (0xD800...0xDBFF).contains(previous)
            && (0xDC00...0xDFFF).contains(next)
        return !splitsSurrogatePair
    }

    private static func isComposedCharacterBoundary(_ offset: Int, in source: String) -> Bool {
        let ns = source as NSString
        guard offset >= 0, offset <= ns.length else { return false }
        guard offset > 0, offset < ns.length else { return true }
        return ns.rangeOfComposedCharacterSequence(at: offset).location == offset
    }
}

enum SourceTokenKind: String, Codable, Hashable, Sendable {
    case word
    case number
    case punctuation
    case symbol
    case combiningMark
    case other
}

enum SourceGeometryQuality: String, Codable, Hashable, Sendable {
    case verifiedCharacter
    case word
    case approximate
    case unknown
}

/// A reading token's source location and the text shown for that token.
/// `sourceSurface` always comes from the untouched canonical source string;
/// display corrections are carried separately by ContextualSelection.
struct SourceToken: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: String
    let documentSHA256: String
    let pageIndex: Int
    let span: UTF16Span
    let sourceSurface: String
    let kind: SourceTokenKind
    let sentenceID: String?
    let blockID: String?
    let geometryQuality: SourceGeometryQuality

    init(documentSHA256: String,
         pageIndex: Int,
         span: UTF16Span,
         sourceSurface: String,
         kind: SourceTokenKind,
         sentenceID: String? = nil,
         blockID: String? = nil,
         geometryQuality: SourceGeometryQuality = .unknown) {
        self.documentSHA256 = documentSHA256
        self.pageIndex = pageIndex
        self.span = span
        self.sourceSurface = sourceSurface
        self.kind = kind
        self.sentenceID = sentenceID
        self.blockID = blockID
        self.geometryQuality = geometryQuality
        self.id = Self.stableID(documentSHA256: documentSHA256,
                                pageIndex: pageIndex,
                                blockID: blockID,
                                span: span)
    }

    func withGeometryQuality(_ quality: SourceGeometryQuality) -> SourceToken {
        SourceToken(documentSHA256: documentSHA256,
                    pageIndex: pageIndex,
                    span: span,
                    sourceSurface: sourceSurface,
                    kind: kind,
                    sentenceID: sentenceID,
                    blockID: blockID,
                    geometryQuality: quality)
    }

    private static func stableID(documentSHA256: String,
                                 pageIndex: Int,
                                 blockID: String?,
                                 span: UTF16Span) -> String {
        let identity = "source-token-v2|\(documentSHA256)|\(pageIndex)|\(blockID ?? "")|\(span.location)|\(span.length)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Exact page source plus its non-destructive token map.
struct CanonicalContent: Equatable, Sendable {
    let documentSHA256: String
    let pageIndex: Int
    let sourceText: String
    let tokens: [SourceToken]
}

/// Selection passed to the contextual card. Source spans and display text are
/// deliberately independent: PDFKit's lookup surface can repair spacing.
struct ContextualSelection: Equatable, Sendable {
    let documentSHA256: String
    let pageIndex: Int
    let sourceSpans: [UTF16Span]
    let tokens: [SourceToken]
    let displaySurface: String
    let generation: Int
    var sentenceContext: SentenceContext? = nil

    var primaryToken: SourceToken? { tokens.first }
}

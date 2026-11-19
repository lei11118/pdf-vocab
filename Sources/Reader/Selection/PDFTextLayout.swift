import UIKit
import PDFKit

/// Character advances from the PDF's own fonts and text operators. No OCR,
/// dictionary, page number or document-specific word rules are involved.
final class PDFTextLayout {
    struct Glyph { let text: String; let rect: CGRect; let baseline: CGPoint }
    /// A stroke-geometry candidate only; it does not identify a math relation.
    struct HorizontalRule { let start: CGPoint; let end: CGPoint; let lineWidth: CGFloat }
    struct PageScan {
        let glyphs: [Glyph]
        let horizontalRules: [HorizontalRule]
        var imageBounds: [CGRect] = []
    }
    private struct Font {
        var unicode: [Int: String] = [:]
        var lengths: [Int] = [1]
        var widths: [Int: CGFloat] = [:]
        var defaultWidth: CGFloat?
        var encoding: String.Encoding = .windowsCP1252
        var fallback: UIFont?
        var supported = true
        var descent: CGFloat = -0.22
        var unit: CGFloat = 0.001
        func decode(_ bytes: [UInt8]) -> [(Int, String, Int)] {
            var result: [(Int,String,Int)] = [], i = 0
            while i < bytes.count {
                var found: (Int,String,Int)?
                for length in lengths where i+length <= bytes.count {
                    let code = bytes[i..<i+length].reduce(0) { ($0 << 8) | Int($1) }
                    if let text = unicode[code] { found = (code,text,length); break }
                }
                if let (code,text,length) = found { result.append((code,text,length)); i += length }
                else {
                    let length = min(lengths.last ?? 1,bytes.count-i)
                    let code = bytes[i..<i+length].reduce(0) { ($0 << 8) | Int($1) }
                    let text = length == 1 ? String(data:Data(bytes[i..<i+length]),encoding:encoding) : nil
                    result.append((code,text ?? "\u{FFFD}",length)); i += length
                }
            }
            return result
        }
        func width(_ code: Int, text: String) -> CGFloat? {
            guard supported else { return nil }
            if let value = widths[code] ?? defaultWidth { return value*unit }
            if let fallback { return (text as NSString).size(withAttributes:[.font:fallback]).width/1000 }
            return nil
        }
    }
    private struct State {
        var ctm = CGAffineTransform.identity
        var text = CGAffineTransform.identity
        var line = CGAffineTransform.identity
        var font: Font?
        var size: CGFloat = 0
        var charSpace: CGFloat = 0
        var wordSpace: CGFloat = 0
        var horizontal: CGFloat = 1
        var leading: CGFloat = 0
        var rise: CGFloat = 0
        var textPositionKnown = true
        var textRenderingMode: CGFloat = 0
        var strokeWidth: CGFloat = 1
    }
    private struct RulePath { let start: CGPoint; var end: CGPoint? }
    private struct PathState { var hasElements = false; var candidate: RulePath? }
    private static let maximumHorizontalRules = 4_096
    private var state = State()
    private var stack: [State] = []
    private var fonts: [String:Font] = [:]
    private var streamID = 0
    private var scanSerial = 0
    private var resources: CGPDFDictionaryRef?
    private var glyphs: [Glyph] = []
    private var horizontalRules: [HorizontalRule] = []
    private var imageBounds: [CGRect] = []
    private var pathState = PathState()
    private let collectsRules: Bool
    private var depth = 0

    private init(collectingRules: Bool = false) { collectsRules = collectingRules }

    static func glyphs(on page: PDFPage) -> [Glyph] {
        scan(on:page,collectingRules:false).glyphs
    }
    static func scan(on page: PDFPage) -> PageScan {
        scan(on:page,collectingRules:true)
    }
    private static func scan(on page: PDFPage, collectingRules: Bool) -> PageScan {
        guard let ref = page.pageRef else { return PageScan(glyphs:[],horizontalRules:[]) }
        let layout = PDFTextLayout(collectingRules:collectingRules)
        var dictionary = ref.dictionary
        for _ in 0..<32 {
            guard let current = dictionary else { break }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current,"Resources",&resources), let resources { layout.resources = resources; break }
            var parent: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(current,"Parent",&parent); dictionary = parent
        }
        let stream = CGPDFContentStreamCreateWithPage(ref)
        defer { CGPDFContentStreamRelease(stream) }
        layout.scan(stream)
        return PageScan(glyphs: layout.glyphs, horizontalRules: layout.horizontalRules, imageBounds: layout.imageBounds)
    }
    private static func owner(_ info: UnsafeMutableRawPointer?) -> PDFTextLayout? {
        info.map { Unmanaged<PDFTextLayout>.fromOpaque($0).takeUnretainedValue() }
    }
    private static func number(_ scanner: CGPDFScannerRef) -> CGFloat {
        var value: CGPDFReal = 0
        CGPDFScannerPopNumber(scanner,&value)
        return CGFloat(value)
    }
    private static func matrix(_ scanner: CGPDFScannerRef) -> CGAffineTransform {
        let f = number(scanner), e = number(scanner), d = number(scanner)
        let c = number(scanner), b = number(scanner), a = number(scanner)
        return CGAffineTransform(a:a,b:b,c:c,d:d,tx:e,ty:f)
    }
    private func scan(_ stream: CGPDFContentStreamRef) {
        guard depth < 16, let table = CGPDFOperatorTableCreate() else { return }
        depth += 1
        let parentID = streamID
        scanSerial += 1; streamID = scanSerial
        defer { streamID = parentID; depth -= 1; CGPDFOperatorTableRelease(table) }
        CGPDFOperatorTableSetCallback(table,"q") { _,p in
            guard let s = PDFTextLayout.owner(p) else { return }; s.stack.append(s.state)
        }
        CGPDFOperatorTableSetCallback(table,"Q") { _,p in
            guard let s = PDFTextLayout.owner(p), let old = s.stack.popLast() else { return }; s.state = old
        }
        CGPDFOperatorTableSetCallback(table,"cm") { scanner,p in
            guard let s = PDFTextLayout.owner(p) else { return }; s.state.ctm = PDFTextLayout.matrix(scanner).concatenating(s.state.ctm)
        }
        if collectsRules {
            CGPDFOperatorTableSetCallback(table,"w") { scanner,p in
                guard let s = PDFTextLayout.owner(p) else { return }; s.state.strokeWidth = PDFTextLayout.number(scanner)
            }
            CGPDFOperatorTableSetCallback(table,"m") { scanner,p in
                guard let s = PDFTextLayout.owner(p) else { return }
                let y = PDFTextLayout.number(scanner), x = PDFTextLayout.number(scanner)
                s.moveTo(x,y)
            }
            CGPDFOperatorTableSetCallback(table,"l") { scanner,p in
                guard let s = PDFTextLayout.owner(p) else { return }
                let y = PDFTextLayout.number(scanner), x = PDFTextLayout.number(scanner)
                s.lineTo(x,y)
            }
            for op in ["c","v","y","h","re","W","W*"] {
                op.withCString { name in
                    CGPDFOperatorTableSetCallback(table,name) { _,p in PDFTextLayout.owner(p)?.invalidatePath() }
                }
            }
            CGPDFOperatorTableSetCallback(table,"S") { _,p in PDFTextLayout.owner(p)?.strokePath() }
            // Closing and stroking a single straight segment still paints the same rule.
            CGPDFOperatorTableSetCallback(table,"s") { _,p in PDFTextLayout.owner(p)?.strokePath() }
            for op in ["f","F","f*","B","B*","b","b*","n"] {
                op.withCString { name in
                    CGPDFOperatorTableSetCallback(table,name) { _,p in PDFTextLayout.owner(p)?.discardPath() }
                }
            }
        }
        CGPDFOperatorTableSetCallback(table,"BT") { _,p in
            guard let s = PDFTextLayout.owner(p) else { return }; s.state.text = .identity; s.state.line = .identity; s.state.textPositionKnown = true
        }
        CGPDFOperatorTableSetCallback(table,"Tm") { scanner,p in
            guard let s = PDFTextLayout.owner(p) else { return }; s.state.text = PDFTextLayout.matrix(scanner); s.state.line = s.state.text; s.state.textPositionKnown = true
        }
        CGPDFOperatorTableSetCallback(table,"Td") { scanner,p in
            guard let s = PDFTextLayout.owner(p) else { return }; let y = PDFTextLayout.number(scanner), x = PDFTextLayout.number(scanner); s.move(x,y)
        }
        CGPDFOperatorTableSetCallback(table,"TD") { scanner,p in
            guard let s = PDFTextLayout.owner(p) else { return }; let y = PDFTextLayout.number(scanner), x = PDFTextLayout.number(scanner); s.state.leading = -y; s.move(x,y)
        }
        CGPDFOperatorTableSetCallback(table,"T*") { _,p in
            guard let s = PDFTextLayout.owner(p) else { return }; s.move(0,-s.state.leading)
        }
        CGPDFOperatorTableSetCallback(table,"Tf") { scanner,p in
            guard let s = PDFTextLayout.owner(p) else { return }
            s.state.size = PDFTextLayout.number(scanner)
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner,&name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner),"Font",name) else { s.state.font = nil; return }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object,.dictionary,&dictionary), let dictionary else { s.state.font = nil; return }
            let key = "\(s.streamID)|\(String(cString:name))"
            let font = s.fonts[key] ?? PDFTextLayout.font(dictionary)
            s.fonts[key] = font; s.state.font = font
        }
        CGPDFOperatorTableSetCallback(table,"Tc") { scanner,p in PDFTextLayout.owner(p)?.state.charSpace = PDFTextLayout.number(scanner) }
        CGPDFOperatorTableSetCallback(table,"Tw") { scanner,p in PDFTextLayout.owner(p)?.state.wordSpace = PDFTextLayout.number(scanner) }
        CGPDFOperatorTableSetCallback(table,"Tz") { scanner,p in PDFTextLayout.owner(p)?.state.horizontal = PDFTextLayout.number(scanner)/100 }
        CGPDFOperatorTableSetCallback(table,"TL") { scanner,p in PDFTextLayout.owner(p)?.state.leading = PDFTextLayout.number(scanner) }
        CGPDFOperatorTableSetCallback(table,"Tr") { scanner,p in
            PDFTextLayout.owner(p)?.state.textRenderingMode = PDFTextLayout.number(scanner)
        }
        CGPDFOperatorTableSetCallback(table,"Ts") { scanner,p in PDFTextLayout.owner(p)?.state.rise = PDFTextLayout.number(scanner) }
        CGPDFOperatorTableSetCallback(table,"Tj") { scanner,p in PDFTextLayout.owner(p)?.showString(scanner) }
        CGPDFOperatorTableSetCallback(table,"'") { scanner,p in
            guard let s = PDFTextLayout.owner(p) else { return }; s.move(0,-s.state.leading); s.showString(scanner)
        }
        CGPDFOperatorTableSetCallback(table,"\"") { scanner,p in
            guard let s = PDFTextLayout.owner(p) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner,&string), let string else { return }
            s.state.charSpace = PDFTextLayout.number(scanner); s.state.wordSpace = PDFTextLayout.number(scanner)
            s.move(0,-s.state.leading); s.show(string)
        }
        CGPDFOperatorTableSetCallback(table,"TJ") { scanner,p in
            guard let s = PDFTextLayout.owner(p) else { return }
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner,&array), let array else { return }
            for i in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?, amount: CGPDFReal = 0
                if CGPDFArrayGetString(array,i,&string), let string { s.show(string) }
                else if CGPDFArrayGetNumber(array,i,&amount) { s.advance(-CGFloat(amount)*s.state.size*s.state.horizontal/1000) }
            }
        }
        CGPDFOperatorTableSetCallback(table,"Do") { scanner,p in PDFTextLayout.owner(p)?.form(scanner) }
        let scanner = CGPDFScannerCreate(stream,table,Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
    }
    private func move(_ x: CGFloat, _ y: CGFloat) {
        state.line = state.line.translatedBy(x:x,y:y); state.text = state.line; state.textPositionKnown = true
    }
    private func advance(_ x: CGFloat) { state.text = state.text.translatedBy(x:x,y:0) }
    private func moveTo(_ x: CGFloat, _ y: CGFloat) {
        let point = CGPoint(x:x,y:y).applying(state.ctm)
        if pathState.hasElements {
            pathState.candidate = nil
        } else {
            pathState.candidate = RulePath(start:point)
        }
        pathState.hasElements = true
    }
    private func lineTo(_ x: CGFloat, _ y: CGFloat) {
        let point = CGPoint(x:x,y:y).applying(state.ctm)
        guard pathState.hasElements, var candidate = pathState.candidate, candidate.end == nil else {
            pathState.hasElements = true
            pathState.candidate = nil
            return
        }
        candidate.end = point
        pathState.candidate = candidate
    }
    private func invalidatePath() {
        pathState.hasElements = true
        pathState.candidate = nil
    }
    private func discardPath() { pathState = PathState() }
    private func strokePath() {
        defer { discardPath() }
        guard horizontalRules.count < Self.maximumHorizontalRules,
              let end = pathState.candidate?.end,
              let start = pathState.candidate?.start,
              start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite,
              state.strokeWidth.isFinite, state.strokeWidth > 0, state.strokeWidth <= 1_000,
              abs(end.y-start.y) <= 0.01 else { return }
        let length = abs(end.x-start.x)
        let determinant = state.ctm.a*state.ctm.d-state.ctm.b*state.ctm.c
        guard length >= 0.1, length <= 1_000_000, determinant.isFinite, abs(determinant) > 0 else { return }
        let inverse = state.ctm.inverted()
        let dx = end.x-start.x, dy = end.y-start.y
        let userLength = hypot(inverse.a*dx+inverse.c*dy,inverse.b*dx+inverse.d*dy)
        guard userLength.isFinite, userLength > 0 else { return }
        let width = abs(determinant)*state.strokeWidth*userLength/length
        guard width.isFinite, width > 0, width <= 1_000 else { return }
        let left = start.x <= end.x ? start : end
        let right = start.x <= end.x ? end : start
        horizontalRules.append(HorizontalRule(start:left,end:right,lineWidth:width))
    }
    private func showString(_ scanner: CGPDFScannerRef) {
        var string: CGPDFStringRef?
        if CGPDFScannerPopString(scanner,&string), let string { show(string) }
    }
    private func show(_ string: CGPDFStringRef) {
        guard let font = state.font, let bytes = CGPDFStringGetBytePtr(string) else { state.textPositionKnown = false; return }
        let count = CGPDFStringGetLength(string)
        guard count <= 100_000 else { return }
        for (code,text,length) in font.decode(Array(UnsafeBufferPointer(start:bytes,count:count))) {
            guard let width = font.width(code,text:text) else { state.font = nil; state.textPositionKnown = false; return }
            let advance = (width*state.size+state.charSpace)*state.horizontal
            // Tc is tracking within a word. Keep Tw/TJ word spacing separate;
            // PDFKit distributes that spacing over neighbouring ranges.
            let rect = CGRect(x:0,y:state.rise+state.size*font.descent,width:advance,height:state.size)
                .applying(state.text.concatenating(state.ctm)).standardized
            let paintsGlyph = state.textRenderingMode != 3 && state.textRenderingMode != 7
            if state.textPositionKnown, (!collectsRules || paintsGlyph), glyphs.count < 100_000,
               rect.width > 0, rect.height > 0 {
                let baseline = CGPoint(x: 0, y: state.rise).applying(state.text.concatenating(state.ctm))
                glyphs.append(Glyph(text: text, rect: rect, baseline: baseline))
            }
            self.advance(advance+(code == 32 && length == 1 ? state.wordSpace*state.horizontal : 0))
        }
    }
    private func form(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?, form: CGPDFStreamRef?
        let parent = CGPDFScannerGetContentStream(scanner)
        guard CGPDFScannerPopName(scanner,&name), let name,
              let object = CGPDFContentStreamGetResource(parent,"XObject",name),
              CGPDFObjectGetValue(object,.stream,&form), let form,
              let dictionary = CGPDFStreamGetDictionary(form) else { return }
        let subtype = Self.name(dictionary,"Subtype")
        if subtype == "Image", collectsRules, imageBounds.count < 512 {
            let bounds = CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.ctm).standardized
            if !bounds.isEmpty && !bounds.isInfinite { imageBounds.append(bounds) }
        }
        guard subtype == "Form" else { return }
        let saved = state, savedStack = stack, savedResources = resources, savedPath = pathState
        pathState = PathState()
        defer { state = saved; stack = savedStack; resources = savedResources; pathState = savedPath }
        if let values = Self.array(dictionary,"Matrix"), CGPDFArrayGetCount(values) == 6 {
            let v = (0..<6).map { Self.real(values,$0) }
            state.ctm = CGAffineTransform(a:v[0],b:v[1],c:v[2],d:v[3],tx:v[4],ty:v[5]).concatenating(state.ctm)
        }
        var formResources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dictionary,"Resources",&formResources)
        guard let effectiveResources = formResources ?? resources else { return }
        resources = effectiveResources
        let child = CGPDFContentStreamCreateWithStream(form,effectiveResources,parent)
        defer { CGPDFContentStreamRelease(child) }
        scan(child)
    }

    private static func name(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        return key.withCString { CGPDFDictionaryGetName(dict,$0,&value) } ? value.map { String(cString:$0) } : nil
    }
    private static func array(_ dict: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef?
        key.withCString { _ = CGPDFDictionaryGetArray(dict,$0,&value) }; return value
    }
    private static func integer(_ array: CGPDFArrayRef, _ index: Int) -> Int {
        var value: CGPDFInteger = 0; CGPDFArrayGetInteger(array,index,&value); return value
    }
    private static func real(_ array: CGPDFArrayRef, _ index: Int) -> CGFloat {
        var value: CGPDFReal = 0; CGPDFArrayGetNumber(array,index,&value); return CGFloat(value)
    }
    private static func font(_ dict: CGPDFDictionaryRef) -> Font {
        var font = Font(), descriptor: CGPDFDictionaryRef?
        var first: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(dict,"FirstChar",&first)
        if let widths = array(dict,"Widths"), (0...65_535).contains(first) {
            for i in 0..<min(CGPDFArrayGetCount(widths),65_536) { font.widths[first+i] = real(widths,i) }
        }
        if let encoding = name(dict,"Encoding") {
            if encoding == "MacRomanEncoding" { font.encoding = .macOSRoman }
            if encoding.hasPrefix("Identity-") { font.lengths = [2] }
            if encoding == "Identity-V" { font.supported = false }
        }
        if let descendants = array(dict,"DescendantFonts") {
            var child: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(descendants,0,&child), let child {
                CGPDFDictionaryGetDictionary(child,"FontDescriptor",&descriptor)
                var value: CGPDFReal = 1000
                CGPDFDictionaryGetNumber(child,"DW",&value); font.defaultWidth = CGFloat(value)
                if let widths = array(child,"W") {
                    var i = 0
                    while i+1 < CGPDFArrayGetCount(widths), font.widths.count < 65_536 {
                        let start = integer(widths,i); i += 1
                        var values: CGPDFArrayRef?
                        if CGPDFArrayGetArray(widths,i,&values), let values {
                            for j in 0..<min(CGPDFArrayGetCount(values),65_536) { font.widths[start+j] = real(values,j) }
                            i += 1
                        } else {
                            guard i+1 < CGPDFArrayGetCount(widths) else { break }
                            let end = integer(widths,i), width = real(widths,i+1); i += 2
                            if start >= 0, start <= end, end < 65_536 { for code in start...end { font.widths[code] = width } }
                        }
                    }
                }
            }
        }
        var ownDescriptor: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dict,"FontDescriptor",&ownDescriptor) { descriptor = ownDescriptor }
        var hasDescent = false
        if let descriptor {
            var descent: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(descriptor,"Descent",&descent), descent <= 0, descent >= -1500 {
                font.descent = CGFloat(descent)/1000; hasDescent = true
            }
            var missing: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(descriptor,"MissingWidth",&missing) { font.defaultWidth = CGFloat(missing) }
        }
        if let matrix = array(dict,"FontMatrix"), CGPDFArrayGetCount(matrix) == 6 { font.unit = real(matrix,0) }
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(dict,"ToUnicode",&stream), let stream {
            var format = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(stream,&format) as Data?, data.count < 4_000_000,
               let text = String(data:data,encoding:.isoLatin1) { readCMap(text,into:&font) }
        }
        // Standard, non-embedded fonts may omit Widths. Use their declared font,
        // never PDFKit's substituted attributed-string font.
        if let base = name(dict,"BaseFont") {
            font.fallback = UIFont(name:base,size:1000)
            if !hasDescent, let fallback = font.fallback { font.descent = fallback.descender/1000 }
            if base.contains("+"), font.unicode.isEmpty, name(dict,"Encoding") == nil { font.supported = false }
        }
        return font
    }
    private static func readCMap(_ text: String, into font: inout Font) {
        let regex = try? NSRegularExpression(pattern:#"<[0-9a-fA-F]+>|\[|\]|[^\s<>\[\]]+"#)
        let clean = text.replacingOccurrences(of:#"%[^\r\n]*"#,with:"",options:.regularExpression)
        let ns = clean as NSString
        let tokens = regex?.matches(in:clean,range:NSRange(location:0,length:ns.length)).map { ns.substring(with:$0.range) } ?? []
        func hex(_ token: String) -> Int? {
            guard token.hasPrefix("<"),token.count <= 10 else { return nil }
            return Int(token.dropFirst().dropLast(),radix:16)
        }
        func unicode(_ token: String) -> String? {
            guard token.hasPrefix("<") else { return nil }
            let chars = Array(token.dropFirst().dropLast()); var bytes: [UInt8] = []
            guard chars.count.isMultiple(of:2), chars.count <= 128 else { return nil }
            for i in stride(from:0,to:chars.count,by:2) {
                guard let byte = UInt8(String(chars[i...i+1]),radix:16) else { return nil }; bytes.append(byte)
            }
            return String(data:Data(bytes),encoding:.utf16BigEndian)
        }
        var i = 0, mode = "", lengths = Set<Int>()
        while i < tokens.count, font.unicode.count < 65_536 {
            let token = tokens[i]
            if token == "beginbfchar" || token == "beginbfrange" { mode = token; i += 1; continue }
            if token.hasPrefix("end") { mode = ""; i += 1; continue }
            guard let code = hex(token) else { i += 1; continue }
            lengths.insert((token.count-2)/2)
            if mode == "beginbfchar", i+1 < tokens.count, let value = unicode(tokens[i+1]) {
                font.unicode[code] = value; i += 2
            } else if mode == "beginbfrange", i+2 < tokens.count, let end = hex(tokens[i+1]), end >= code, end-code < 65_536 {
                if tokens[i+2] == "[" {
                    i += 3
                    for c in code...end {
                        guard i < tokens.count, let value = unicode(tokens[i]) else { break }
                        font.unicode[c] = value; i += 1
                    }
                    if i < tokens.count, tokens[i] == "]" { i += 1 }
                } else if let destination = hex(tokens[i+2]) {
                    let digits = tokens[i+2].count-2
                    for c in code...end {
                        let token = String(format:"<%0*X>",digits,destination+c-code)
                        if let value = unicode(token) { font.unicode[c] = value }
                    }
                    i += 3
                } else { i += 1 }
            } else { i += 1 }
        }
        if !lengths.isEmpty { font.lengths = lengths.sorted(by:>) }
    }
}

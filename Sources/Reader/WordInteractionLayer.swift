import SwiftUI
import UIKit
import PencilKit
import NaturalLanguage

/// Common dictionary/translation/speech behavior for page and graph adapters.
enum WordInteraction {
    static func detail(_ term: String) -> String? {
        guard case .found(let entry) = DictionaryService.lookup(term) else { return nil }
        return entry.translation ?? entry.definition
    }
    @MainActor static func speak(_ term: String) {
        let language = NLLanguageRecognizer.dominantLanguage(for: term)?.rawValue ?? "en"
        SpeechService.shared.speak(term, language: language == "en" ? SpeechService.usVoice : language)
    }
    static func hit(_ point: CGPoint, words: [GraphWord]) -> Int? {
        words.indices.filter { words[$0].rect.contains(point) }.min {
            words[$0].rect.width * words[$0].rect.height < words[$1].rect.width * words[$1].rect.height
        }
    }
}

/// Text and screenshot adapters produce normalized word rectangles for one interaction view.
struct WordInteractionLayer: UIViewRepresentable {
    var text: String = ""
    var image: UIImage?
    var words: [GraphWord] = []
    var enabled = true
    var onEdit: (() -> Void)?
    func makeUIView(context: Context) -> WordInteractionView { WordInteractionView() }
    func updateUIView(_ view: WordInteractionView, context: Context) {
        view.configure(text: text, image: image, words: words, enabled: enabled)
        view.onEdit = onEdit
    }
}

final class WordInteractionView: UIView, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    private let label = UILabel()
    private let picture = UIImageView()
    private let highlight = CAShapeLayer()
    private let bubble = UILabel()
    private var words: [GraphWord] = []
    private var supplied: [GraphWord] = []
    private var text = ""
    private var image: UIImage?
    private var enabled = true
    private var selection: ClosedRange<Int>?
    private var start: Int?
    private var hoverIndex: Int?
    private var hoverTask: Task<Void, Never>?
    private var translatedTerm: String?
    var onEdit: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0; label.font = .systemFont(ofSize: 18)
        label.textColor = .label; picture.contentMode = .scaleToFill
        addSubview(picture); addSubview(label)
        highlight.fillColor = UIColor.systemBlue.withAlphaComponent(0.22).cgColor
        layer.addSublayer(highlight)
        bubble.numberOfLines = 0; bubble.font = .systemFont(ofSize: 13)
        bubble.backgroundColor = .secondarySystemBackground; bubble.layer.cornerRadius = 8
        bubble.clipsToBounds = true; bubble.isHidden = true
        addSubview(bubble)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(edit(_:))); double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        addGestureRecognizer(tap); addGestureRecognizer(double)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(press(_:)))
        press.minimumPressDuration = 0.4; addGestureRecognizer(press)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.delegate = self; addGestureRecognizer(pan)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        let pencil = UIPencilInteraction(); pencil.delegate = self; addInteraction(pencil)
        isAccessibilityElement = true; accessibilityTraits = .staticText
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(text: String, image: UIImage?, words: [GraphWord], enabled: Bool) {
        guard self.text != text || self.image !== image || supplied != words || self.enabled != enabled else { return }
        self.text = text; self.image = image; supplied = words; self.enabled = enabled
        label.text = text; picture.image = image; label.isHidden = image != nil
        selection = nil; accessibilityLabel = image == nil ? text : words.map(\.text).joined(separator: " ")
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        picture.frame = bounds
        let inset: CGFloat = image == nil ? 12 : 0
        let rect = bounds.insetBy(dx: inset, dy: inset)
        label.frame = rect
        words = image == nil ? textWords(rect: rect) : supplied
        redraw()
    }
    private func textWords(rect: CGRect) -> [GraphWord] {
        guard rect.width > 0, rect.height > 0, !text.isEmpty else { return [] }
        let storage = NSTextStorage(string: text, attributes: [.font: label.font as Any])
        let manager = NSLayoutManager(), container = NSTextContainer(size: rect.size)
        container.lineFragmentPadding = 0; container.maximumNumberOfLines = 0
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var result: [GraphWord] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word else { return }
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(range, in: self.text), actualCharacterRange: nil)
            var box = manager.boundingRect(forGlyphRange: glyphs, in: container)
            box.origin.x += rect.minX; box.origin.y += rect.minY
            guard box.intersects(rect) else { return }
            result.append(GraphWord(text: word, rect: CGRect(x: box.minX/self.bounds.width, y: box.minY/self.bounds.height, width: box.width/self.bounds.width, height: box.height/self.bounds.height)))
        }
        // Match UILabel top alignment with the exact TextKit layout.
        let used = manager.usedRect(for: container)
        label.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, used.height))
        return result
    }
    private func hit(_ point: CGPoint) -> Int? {
        guard enabled, bounds.width > 0, bounds.height > 0 else { return nil }
        return WordInteraction.hit(CGPoint(x: point.x/bounds.width, y: point.y/bounds.height), words: words)
    }
    private func redraw() {
        let path = UIBezierPath()
        if let selection { for index in selection where words.indices.contains(index) {
            let r = words[index].rect
            path.append(UIBezierPath(rect: CGRect(x: r.minX*bounds.width,y: r.minY*bounds.height,width:r.width*bounds.width,height:r.height*bounds.height)))
        } }
        highlight.path = path.cgPath
    }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        guard let index = hit(gesture.location(in: self)) else { selection = nil; redraw(); bubble.isHidden = true; return }
        selection = index...index; redraw(); translate(words[index].text, at: gesture.location(in: self))
    }
    @objc private func edit(_ gesture: UITapGestureRecognizer) { if image == nil { onEdit?() } }
    @objc private func press(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began, let index = hit(gesture.location(in: self)) { selection = index...index; redraw() }
        if gesture.state == .ended { showMenu(at: gesture.location(in: self)) }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer else { return true }
        return hit(gestureRecognizer.location(in: self)) != nil
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { start = hit(gesture.location(in: self)) }
        if let start, let end = hit(gesture.location(in: self)) { selection = min(start,end)...max(start,end); redraw() }
        if gesture.state == .ended { showMenu(at: gesture.location(in: self)); start = nil }
    }
    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        let index = gesture.state == .ended || gesture.state == .cancelled ? nil : hit(gesture.location(in: self))
        guard index != hoverIndex else { return }
        hoverIndex = index; hoverTask?.cancel(); translatedTerm = nil; bubble.isHidden = true
        guard let index else { return }
        let term = words[index].text, point = gesture.location(in: self)
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: ToolArcConfig.hoverDelay)
            guard !Task.isCancelled else { return }
            self?.translate(term, at: point)
        }
    }
    private func translate(_ term: String, at point: CGPoint) {
        Task { @MainActor [weak self] in
            let detail = await Task.detached { WordInteraction.detail(term) }.value
            guard let self, let detail else { return }
            guard self.hoverIndex.map({ self.words[$0].text == term }) ?? (self.selectedText == term) else { return }
            self.bubble.text = "  \(term)\n  \(String(detail.prefix(350)))"
            self.bubble.frame = CGRect(x: 4, y: max(0, point.y - 100), width: max(100, self.bounds.width - 8), height: min(110, self.bounds.height))
            self.bubble.isHidden = false; self.translatedTerm = term
        }
    }
    private var selectedText: String {
        guard let selection else { return "" }
        return selection.compactMap { words.indices.contains($0) ? words[$0].text : nil }.joined(separator: " ")
    }
    private func showMenu(at point: CGPoint) {
        guard !selectedText.isEmpty else { return }
        becomeFirstResponder()
        let menu = UIMenu(children: [
            UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in UIPasteboard.general.string = self?.selectedText },
            UIAction(title: "翻译", image: UIImage(systemName: "character.bubble")) { [weak self] _ in guard let self else { return }; self.translate(self.selectedText, at: point) },
            UIAction(title: "朗读", image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in if let self { WordInteraction.speak(self.selectedText) } }
        ])
        menuValue = menu
        if editInteraction == nil {
            let interaction = UIEditMenuInteraction(delegate: self); addInteraction(interaction); editInteraction = interaction
        }
        editInteraction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }
    private var menuValue: UIMenu?
    private var editInteraction: UIEditMenuInteraction?
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended, hoverIndex != nil, !bubble.isHidden, let translatedTerm else { return }
        WordInteraction.speak(translatedTerm)
    }
}
extension WordInteractionView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? { menuValue }
}

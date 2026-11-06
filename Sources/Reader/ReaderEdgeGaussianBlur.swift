import CoreImage
import PDFKit
import PencilKit
import QuartzCore
import SwiftUI
import UIKit

struct ReaderEdgeGaussianBlurBand: Equatable {
    enum Edge: Equatable {
        case top
        case bottom
    }

    let edge: Edge
    let frame: CGRect
    let opaqueLength: CGFloat
    let fadeLength: CGFloat

    var gradientLocations: [NSNumber] {
        guard frame.height > 0 else { return [0, 1] }
        let fadeStart = edge == .top ? opaqueLength / frame.height : fadeLength / frame.height
        return [0, NSNumber(value: Double(fadeStart)), 1]
    }

    func configure(mask: CAGradientLayer, size: CGSize) {
        let opaque = UIColor.white.cgColor
        let clear = UIColor.white.withAlphaComponent(0).cgColor
        mask.frame = CGRect(origin: .zero, size: size)
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        mask.locations = gradientLocations
        mask.colors = edge == .top
            ? [opaque, opaque, clear]
            : [clear, opaque, opaque]
    }
}

struct ReaderEdgeGaussianBlurLayout: Equatable {
    static let fadeLength: CGFloat = 32

    let top: ReaderEdgeGaussianBlurBand?
    let bottom: ReaderEdgeGaussianBlurBand?

    init(bounds: CGRect, safeAreaInsets: UIEdgeInsets) {
        let height = max(bounds.height, 0)
        let topInset = min(height, max(safeAreaInsets.top, 0))
        let bottomInset = min(max(height - topInset, 0), max(safeAreaInsets.bottom, 0))
        let transitionSpace = max(height - topInset - bottomInset, 0)
        let hasBothEdges = topInset > 0 && bottomInset > 0
        let topFade = topInset > 0
            ? min(Self.fadeLength, hasBothEdges ? transitionSpace / 2 : transitionSpace)
            : 0
        let bottomFade = bottomInset > 0
            ? min(Self.fadeLength, max(transitionSpace - topFade, 0))
            : 0

        if topInset > 0 {
            let bandHeight = topInset + topFade
            top = ReaderEdgeGaussianBlurBand(
                edge: .top,
                frame: CGRect(x: bounds.minX, y: bounds.minY,
                              width: max(bounds.width, 0), height: bandHeight),
                opaqueLength: topInset,
                fadeLength: topFade
            )
        } else {
            top = nil
        }

        if bottomInset > 0 {
            let bandHeight = bottomInset + bottomFade
            bottom = ReaderEdgeGaussianBlurBand(
                edge: .bottom,
                frame: CGRect(x: bounds.minX, y: bounds.maxY - bandHeight,
                              width: max(bounds.width, 0), height: bandHeight),
                opaqueLength: bottomInset,
                fadeLength: bottomFade
            )
        } else {
            bottom = nil
        }
    }
}

struct ReaderSafeAreaGaussianBlurOverlay: UIViewRepresentable {
    let pdfViewProvider: () -> PDFView?
    let isSceneActive: Bool

    func makeUIView(context: Context) -> ReaderEdgeGaussianBlurView {
        ReaderEdgeGaussianBlurView(pdfViewProvider: pdfViewProvider,
                                   isSceneActive: isSceneActive)
    }

    func updateUIView(_ uiView: ReaderEdgeGaussianBlurView, context: Context) {
        uiView.update(pdfViewProvider: pdfViewProvider, isSceneActive: isSceneActive)
    }
}

final class ReaderEdgeGaussianBlurView: UIView {
    private let topImageView = UIImageView()
    private let bottomImageView = UIImageView()
    private let topMask = CAGradientLayer()
    private let bottomMask = CAGradientLayer()
    private var pdfViewProvider: () -> PDFView?
    private var isSceneActive: Bool
    private var layout: ReaderEdgeGaussianBlurLayout?
    private var captureTimer: Timer?
    private var isProcessing = false
    private var captureRequested = false
    private var lastCaptureTime = -Double.infinity
    private var sourceObservations: [NSKeyValueObservation] = []
    private var observedMotionObjectIDs = Set<ObjectIdentifier>()
    private var generation = 0
    private weak var observedPDFView: PDFView?
    private weak var observedDocument: PDFDocument?
    private var pageObserver: NSObjectProtocol?
    private var selectionObserver: NSObjectProtocol?
    private var documentObserver: NSObjectProtocol?

    init(pdfViewProvider: @escaping () -> PDFView?, isSceneActive: Bool) {
        self.pdfViewProvider = pdfViewProvider
        self.isSceneActive = isSceneActive
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        accessibilityElementsHidden = true

        for imageView in [topImageView, bottomImageView] {
            imageView.isUserInteractionEnabled = false
            imageView.isOpaque = false
            imageView.backgroundColor = .clear
            imageView.isAccessibilityElement = false
            imageView.contentMode = .scaleToFill
            imageView.layer.masksToBounds = true
            addSubview(imageView)
        }
        topImageView.layer.mask = topMask
        bottomImageView.layer.mask = bottomMask
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        captureTimer?.invalidate()
        if let pageObserver {
            NotificationCenter.default.removeObserver(pageObserver)
        }
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
        if let documentObserver {
            NotificationCenter.default.removeObserver(documentObserver)
        }
    }

    func update(pdfViewProvider: @escaping () -> PDFView?, isSceneActive: Bool) {
        self.pdfViewProvider = pdfViewProvider
        if self.isSceneActive != isSceneActive {
            self.isSceneActive = isSceneActive
            generation &+= 1
            cancelPendingCapture()
            clearImages()
            if isSceneActive { requestCapture() }
        }
        refreshDocumentObservation()
        reconcileCaptureEligibility()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        generation &+= 1
        clearImages()
        refreshDocumentObservation()
        reconcileCaptureEligibility()
        requestCapture()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
        layoutIfNeeded()
        reconcileCaptureEligibility()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let nextLayout = ReaderEdgeGaussianBlurLayout(
            bounds: bounds,
            safeAreaInsets: window?.safeAreaInsets ?? safeAreaInsets
        )
        if layout != nextLayout {
            layout = nextLayout
            generation &+= 1
            clearImages()
            requestCapture()
        }

        if let top = nextLayout.top {
            topImageView.frame = top.frame
            top.configure(mask: topMask, size: topImageView.bounds.size)
        } else {
            topImageView.frame = .zero
            topImageView.image = nil
        }
        if let bottom = nextLayout.bottom {
            bottomImageView.frame = bottom.frame
            bottom.configure(mask: bottomMask, size: bottomImageView.bounds.size)
        } else {
            bottomImageView.frame = .zero
            bottomImageView.image = nil
        }
        reconcileCaptureEligibility()
    }

    private func refreshDocumentObservation() {
        let candidate = pdfViewProvider()
        if candidate === observedPDFView {
            if candidate?.document !== observedDocument {
                observedDocument = candidate?.document
                generation &+= 1
                clearImages()
                observedMotionObjectIDs.removeAll()
                if let candidate { refreshMotionObservationsIfNeeded(for: candidate) }
                requestCapture()
            }
            return
        }
        if let pageObserver {
            NotificationCenter.default.removeObserver(pageObserver)
            self.pageObserver = nil
        }
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
            self.selectionObserver = nil
        }
        if let documentObserver {
            NotificationCenter.default.removeObserver(documentObserver)
            self.documentObserver = nil
        }
        sourceObservations.removeAll()
        observedMotionObjectIDs.removeAll()
        observedPDFView = candidate
        observedDocument = candidate?.document
        generation &+= 1
        clearImages()

        guard let candidate else { return }
        refreshMotionObservationsIfNeeded(for: candidate)
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: candidate,
            queue: .main
        ) { [weak self, weak candidate] _ in
            guard let self, let candidate else { return }
            self.refreshMotionObservationsIfNeeded(for: candidate)
            self.requestCapture()
        }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewSelectionChanged,
            object: candidate,
            queue: .main
        ) { [weak self] _ in
            self?.requestCapture()
        }
        documentObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewDocumentChanged,
            object: candidate,
            queue: .main
        ) { [weak self, weak candidate] _ in
            guard let self, let candidate else { return }
            self.observedDocument = candidate.document
            self.generation &+= 1
            self.clearImages()
            self.observedMotionObjectIDs.removeAll()
            self.refreshMotionObservationsIfNeeded(for: candidate)
            self.requestCapture()
        }
        requestCapture()
    }

    @discardableResult
    private func refreshMotionObservationsIfNeeded(for candidate: PDFView) -> Bool {
        let scrollViews = PencilTouchIsolation.scrollViews(in: candidate)
        let canvases = canvasViews(in: candidate)
        var nextIDs = Set([ObjectIdentifier(candidate)])
        scrollViews.forEach { nextIDs.insert(ObjectIdentifier($0)) }
        canvases.forEach { nextIDs.insert(ObjectIdentifier($0)) }
        guard nextIDs != observedMotionObjectIDs else { return false }

        observedMotionObjectIDs = nextIDs
        sourceObservations.removeAll()
        sourceObservations.append(candidate.observe(\.scaleFactor, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.requestCapture() }
        })
        sourceObservations.append(candidate.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.requestCapture() }
        })
        for scrollView in scrollViews {
            sourceObservations.append(scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.requestCapture() }
            })
            sourceObservations.append(scrollView.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.requestCapture() }
            })
        }
        for canvas in canvases {
            sourceObservations.append(canvas.observe(\.drawing, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.requestCapture() }
            })
        }
        return true
    }

    private func canvasViews(in root: UIView) -> [PKCanvasView] {
        var result: [PKCanvasView] = []
        func visit(_ view: UIView) {
            if let canvas = view as? PKCanvasView {
                result.append(canvas)
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return result
    }

    private func reconcileCaptureEligibility() {
        refreshDocumentObservation()
        let pdfView = pdfViewProvider()
        if let pdfView, refreshMotionObservationsIfNeeded(for: pdfView) {
            requestCapture()
        }
        guard isEligibleForCapture(pdfView) else {
            cancelPendingCapture()
            clearImages()
            return
        }
        scheduleCapture()
    }

    private func isEligibleForCapture(_ pdfView: PDFView?) -> Bool {
        guard isSceneActive,
              let window,
              !window.isHidden,
              window.alpha > 0,
              window.windowScene?.activationState == .foregroundActive,
              !isHidden,
              alpha > 0,
              let pdfView,
              pdfView.window === window,
              pdfView.document != nil,
              pdfView.bounds.width > 0,
              pdfView.bounds.height > 0 else {
            return false
        }
        var ancestor: UIView? = pdfView
        while let view = ancestor, view !== window {
            guard !view.isHidden, view.alpha > 0 else { return false }
            ancestor = view.superview
        }
        guard ancestor === window else { return false }
        let visibleRect = pdfView.convert(pdfView.bounds, to: window).intersection(window.bounds)
        return !visibleRect.isNull && visibleRect.width > 1 && visibleRect.height > 1
    }

    private func captureIfNeeded() {
        captureTimer = nil
        guard captureRequested, !isProcessing else { return }
        guard let layout,
              let pdfView = pdfViewProvider(),
              isEligibleForCapture(pdfView) else {
            cancelPendingCapture()
            clearImages()
            return
        }
        captureRequested = false
        if observedDocument !== pdfView.document {
            observedDocument = pdfView.document
            generation &+= 1
            clearImages()
            observedMotionObjectIDs.removeAll()
            refreshMotionObservationsIfNeeded(for: pdfView)
        }

        let requestGeneration = generation
        let requestDocument = pdfView.document
        isProcessing = true
        lastCaptureTime = CACurrentMediaTime()
        let topCapture = layout.top.flatMap { capture($0, from: pdfView) }
        let bottomCapture = layout.bottom.flatMap { capture($0, from: pdfView) }
        guard topCapture != nil || bottomCapture != nil else {
            isProcessing = false
            clearImages()
            if captureRequested { scheduleCapture() }
            return
        }

        ReaderEdgeGaussianBlurProcessor.processingQueue.async { [weak self] in
            let topBlurred = topCapture.flatMap(ReaderEdgeGaussianBlurProcessor.gaussianBlur)
            let bottomBlurred = bottomCapture.flatMap(ReaderEdgeGaussianBlurProcessor.gaussianBlur)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessing = false
                guard self.generation == requestGeneration,
                      self.isSceneActive,
                      let currentPDFView = self.pdfViewProvider(),
                      currentPDFView === pdfView,
                      currentPDFView.document === requestDocument,
                      self.window != nil else {
                    if self.captureRequested { self.scheduleCapture() }
                    return
                }
                self.topImageView.image = topBlurred.map {
                    UIImage(cgImage: $0,
                            scale: ReaderEdgeGaussianBlurProcessor.captureScale,
                            orientation: .up)
                }
                self.bottomImageView.image = bottomBlurred.map {
                    UIImage(cgImage: $0,
                            scale: ReaderEdgeGaussianBlurProcessor.captureScale,
                            orientation: .up)
                }
                if self.captureRequested { self.scheduleCapture() }
            }
        }
    }

    private func capture(_ band: ReaderEdgeGaussianBlurBand, from pdfView: PDFView) -> CGImage? {
        let overlayRect = band.frame.intersection(bounds)
        guard !overlayRect.isNull, overlayRect.width > 1, overlayRect.height > 1 else { return nil }
        let pdfRect = pdfView.convert(overlayRect, from: self).intersection(pdfView.bounds)
        guard !pdfRect.isNull, pdfRect.width > 1, pdfRect.height > 1 else { return nil }
        let overlayPDFIntersection = pdfView.convert(pdfRect, to: self).intersection(overlayRect)
        guard !overlayPDFIntersection.isNull else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = ReaderEdgeGaussianBlurProcessor.captureScale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: overlayRect.size, format: format)
        var didDraw = false
        let sourceInOverlay = pdfView.convert(pdfView.bounds, to: self)
        let destination = sourceInOverlay.offsetBy(dx: -overlayRect.minX, dy: -overlayRect.minY)
        let image = renderer.image { context in
            let localIntersection = overlayPDFIntersection.offsetBy(dx: -overlayRect.minX,
                                                                     dy: -overlayRect.minY)
            context.cgContext.clip(to: localIntersection)
            didDraw = pdfView.drawHierarchy(in: destination, afterScreenUpdates: false)
        }
        return didDraw ? image.cgImage : nil
    }

    private func requestCapture() {
        guard isEligibleForCapture(pdfViewProvider()) else {
            cancelPendingCapture()
            clearImages()
            return
        }
        captureRequested = true
        scheduleCapture()
    }

    private func scheduleCapture() {
        guard captureRequested, !isProcessing, captureTimer == nil else { return }
        let minimumInterval = 1.0 / 15.0
        let remaining = minimumInterval - (CACurrentMediaTime() - lastCaptureTime)
        if remaining <= 0 {
            captureIfNeeded()
            return
        }
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            self?.captureIfNeeded()
        }
        captureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelPendingCapture() {
        captureTimer?.invalidate()
        captureTimer = nil
        captureRequested = false
    }

    private func clearImages() {
        topImageView.image = nil
        bottomImageView.image = nil
    }
}

enum ReaderEdgeGaussianBlurProcessor {
    static let captureScale: CGFloat = 0.5
    // At half-point capture scale this is a 20-point Gaussian radius.
    private static let gaussianRadius: CGFloat = 10
    static let processingQueue = DispatchQueue(label: "reader.edge-blur", qos: .userInitiated)
    private static let ciContext = CIContext()

    static func gaussianBlur(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: gaussianRadius])
            .cropped(to: extent)
        return ciContext.createCGImage(blurred, from: extent)
    }
}

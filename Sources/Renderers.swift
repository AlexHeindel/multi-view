import SwiftUI
import AppKit
import PDFKit

// ponytail: fixed wheel sensitivity; expose a setting if different mice need calibration.
private func wheelZoomFactor(_ event: NSEvent) -> CGFloat {
    let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
    // One mouse notch may report several lines, so cap each event at one zoom step.
    return CGFloat(pow(1.08, Double(max(-1, min(1, delta)))))
}

final class CenteredClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        // Manual pan/zoom must keep its anchor even when the image is smaller than the pane.
        if let scroll = enclosingScrollView as? ImageScrollView, !scroll.fitting { return proposedBounds }
        var result = super.constrainBoundsRect(proposedBounds)
        if let documentView {
            if documentView.frame.width < result.width {
                result.origin.x = (documentView.frame.width - result.width) / 2
            }
            if documentView.frame.height < result.height {
                result.origin.y = (documentView.frame.height - result.height) / 2
            }
        }
        return result
    }
}

final class PassiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ImageCanvas: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var vectorImage: NSImage? { didSet { needsDisplay = true } }
    let animation = PassiveImageView()
    var activate: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        animation.animates = true
        animation.imageScaling = .scaleAxesIndependently
        animation.isHidden = true
        addSubview(animation)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        animation.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)
        if let image {
            context.interpolationQuality = .high
            context.draw(image, in: bounds)
        } else {
            vectorImage?.draw(in: bounds)
        }
    }

    override func mouseDown(with event: NSEvent) {
        activate?()
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        (enclosingScrollView as? ImageScrollView)?.pan(by: NSPoint(x: event.deltaX, y: event.deltaY))
    }

    override func mouseUp(with event: NSEvent) { NSCursor.pop() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

final class ImageScrollView: NSScrollView {
    let canvas = ImageCanvas(frame: .zero)
    var raster: Raster?
    var nativeImage: NSImage?
    var imageSize: CGSize { raster?.size ?? nativeImage?.size ?? .zero }
    var requestDetail: (() -> Void)?
    var lastCommand = -1
    var fitting = true

    init() {
        super.init(frame: .zero)
        contentView = CenteredClipView()
        drawsBackground = true
        backgroundColor = .underPageBackgroundColor
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.00001
        maxMagnification = 32
        documentView = canvas
        setAccessibilityLabel("Plot image. Pinch or scroll to zoom; drag to pan.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ raster: Raster) {
        let first = self.raster == nil && nativeImage == nil
        self.raster = raster
        nativeImage = nil
        canvas.frame = CGRect(origin: .zero, size: raster.size)
        canvas.vectorImage = nil
        canvas.animation.image = nil
        canvas.animation.isHidden = true
        canvas.image = raster.image
        if first { fit() }
        checkDetail()
    }

    func display(_ image: NSImage, animated: Bool) {
        let first = raster == nil && nativeImage == nil
        raster = nil
        nativeImage = image
        canvas.frame = CGRect(origin: .zero, size: image.size)
        canvas.image = nil
        canvas.vectorImage = animated ? nil : image
        canvas.animation.image = animated ? image : nil
        canvas.animation.isHidden = !animated
        if first { fit() }
    }

    func fit() {
        fitting = true
        let size = imageSize
        guard size.width > 0, size.height > 0, contentSize.width > 1, contentSize.height > 1 else { return }
        let scale = min(contentSize.width / size.width, contentSize.height / size.height)
        setMagnification(max(minMagnification, min(maxMagnification, scale)),
                         centeredAt: NSPoint(x: size.width / 2, y: size.height / 2))
        checkDetail()
    }

    func actualSize() {
        let scale = 1 / (window?.backingScaleFactor ?? 2)
        zoom(by: scale / magnification)
    }

    override func layout() {
        super.layout()
        if fitting { fit() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if fitting { fit() }
    }

    override func magnify(with event: NSEvent) {
        canvas.activate?()
        zoom(by: 1 + event.magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        canvas.activate?()
        // Native elastic scrolling cannot constrain our freely panned clip view.
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            pan(by: NSPoint(x: event.scrollingDeltaX, y: 0))
        } else if event.scrollingDeltaY != 0 {
            zoom(by: wheelZoomFactor(event))
        }
    }

    func pan(by delta: NSPoint) {
        fitting = false
        let origin = contentView.bounds.origin
        contentView.scroll(to: NSPoint(x: origin.x - delta.x / magnification,
                                      y: origin.y + delta.y / magnification))
        reflectScrolledClipView(contentView)
    }

    private func zoom(by factor: CGFloat) {
        fitting = false
        let point = canvas.convert(NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY),
                                   from: contentView)
        setMagnification(max(minMagnification, min(maxMagnification, magnification * factor)),
                         centeredAt: point)
        checkDetail()
    }

    private func checkDetail() {
        guard let raster, !raster.fullDetail else { return }
        let requiredWidth = raster.size.width * magnification * (window?.backingScaleFactor ?? 2)
        if requiredWidth > CGFloat(raster.image.width) + 0.5 {
            // Defer model changes until after the SwiftUI/AppKit update has finished.
            let request = requestDetail
            DispatchQueue.main.async { request?() }
        }
    }

    func applyCommand(_ pane: Pane) {
        guard lastCommand != pane.commandNumber else { return }
        lastCommand = pane.commandNumber
        switch pane.command {
        case .fit: fit()
        case .actualSize: actualSize()
        }
    }
}

struct RasterView: NSViewRepresentable {
    @ObservedObject var pane: Pane
    let raster: Raster
    let activate: () -> Void

    func makeNSView(context: Context) -> ImageScrollView { ImageScrollView() }

    func updateNSView(_ view: ImageScrollView, context: Context) {
        view.canvas.activate = activate
        view.requestDetail = { [weak pane] in pane?.requestFullDetail() }
        if view.raster !== raster { view.display(raster) }
        view.applyCommand(pane)
    }
}

struct NativeImageView: NSViewRepresentable {
    @ObservedObject var pane: Pane
    let image: NSImage
    let activate: () -> Void

    func makeNSView(context: Context) -> ImageScrollView { ImageScrollView() }

    func updateNSView(_ view: ImageScrollView, context: Context) {
        view.canvas.activate = activate
        view.requestDetail = nil
        if view.nativeImage !== image {
            view.display(image, animated: pane.current?.pathExtension.lowercased() == "gif")
        }
        view.applyCommand(pane)
    }
}

final class PlotPDFView: PDFView {
    var activate: (() -> Void)?
    private var wheelMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        guard window != nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                  event.scrollingDeltaY != 0 else { return event }
            self.scrollWheel(with: event)
            return nil
        }
    }

    deinit { if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) } }

    override func mouseDown(with event: NSEvent) {
        activate?()
        super.mouseDown(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        activate?()
        guard event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        wheelZoom(by: wheelZoomFactor(event))
    }

    private func wheelZoom(by factor: CGFloat) {
        let scale = scaleFactor
        autoScales = false
        scaleFactor = max(minScaleFactor, min(maxScaleFactor, scale * factor))
    }
    override func magnify(with event: NSEvent) {
        activate?()
        super.magnify(with: event)
    }
}

struct DocumentView: NSViewRepresentable {
    @ObservedObject var pane: Pane
    let document: PDFDocument
    let activate: () -> Void

    final class Coordinator {
        var lastCommand = -1
        var observation: NSObjectProtocol?
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlotPDFView {
        let view = PlotPDFView()
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.displaysPageBreaks = false
        view.backgroundColor = .underPageBackgroundColor
        view.minScaleFactor = 0.01
        view.maxScaleFactor = 32
        view.setAccessibilityLabel("PDF plot. Pinch or scroll to zoom.")
        context.coordinator.observation = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main
        ) { [weak pane, weak view] _ in
            guard let view, let page = view.currentPage, let document = view.document else { return }
            let index = document.index(for: page)
            DispatchQueue.main.async {
                guard let pane, pane.pdf === document, pane.pdfPage != index else { return }
                pane.pdfPage = index
            }
        }
        return view
    }

    func updateNSView(_ view: PlotPDFView, context: Context) {
        view.activate = activate
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
        if let page = document.page(at: pane.pdfPage), view.currentPage !== page { view.go(to: page) }
        if context.coordinator.lastCommand != pane.commandNumber {
            context.coordinator.lastCommand = pane.commandNumber
            switch pane.command {
            case .fit: view.autoScales = true
            case .actualSize:
                view.autoScales = false
                view.scaleFactor = 1
            }
        }
    }
}

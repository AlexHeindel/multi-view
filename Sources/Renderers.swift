import SwiftUI
import AppKit
import PDFKit

final class CenteredClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
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
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.x -= event.deltaX / scroll.magnification
        origin.y += event.deltaY / scroll.magnification
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
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
        setAccessibilityLabel("Plot image. Pinch to zoom; drag or scroll to pan.")
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
        fitting = false
        let scale = 1 / (window?.backingScaleFactor ?? 2)
        setMagnification(scale, centeredAt: NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        checkDetail()
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
        fitting = false
        super.magnify(with: event)
        checkDetail()
    }

    override func scrollWheel(with event: NSEvent) {
        canvas.activate?()
        super.scrollWheel(with: event)
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
    override func mouseDown(with event: NSEvent) {
        activate?()
        super.mouseDown(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        activate?()
        super.scrollWheel(with: event)
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
        view.setAccessibilityLabel("PDF plot. Pinch to zoom; scroll to pan.")
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

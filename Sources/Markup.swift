import SwiftUI
import AppKit

enum MarkupTool: String, CaseIterable {
    case navigate = "Navigate", pen = "Pen", eraser = "Eraser"
}

final class MarkupSettings: ObservableObject {
    static let eraserWidth: CGFloat = 18
    @Published var tool: MarkupTool = .navigate
    @Published var width: CGFloat = 4
    @Published var color = Color.red
}

struct MarkupStroke {
    // Pane-relative coordinates keep marks in their pane when the layout resizes.
    var points: [CGPoint]
    let color: NSColor
    let width: CGFloat
    let erasing: Bool
}

struct MarkupControls: View {
    @ObservedObject var settings: MarkupSettings
    let wipeAll: () -> Void
    @State private var showing = false

    var body: some View {
        Button {
            if settings.tool == .navigate { settings.tool = .pen }
            showing.toggle()
        } label: {
            Label("Markup", systemImage: "pencil.tip.crop.circle")
                .foregroundStyle(settings.tool == .navigate ? Color.primary : Color.accentColor)
        }
        .help("Draw temporary marks in each pane")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pane Markup").font(.headline)
                Picker("Tool", selection: $settings.tool) {
                    ForEach(MarkupTool.allCases, id: \.self) { tool in
                        Text(tool.rawValue).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                if settings.tool == .pen {
                    Picker("Line thickness", selection: $settings.width) {
                        ForEach([2, 4, 8, 12], id: \.self) { width in
                            Text("\(width) pt").tag(CGFloat(width))
                        }
                    }
                    ColorPicker("Pen color", selection: $settings.color, supportsOpacity: false)
                }
                Text("Drag inside a pane to draw or erase. Choose Navigate to pan and zoom.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button("Wipe All Panes", role: .destructive) { wipeAll() }
                        .help("Erase drawings in every pane, including other tabs")
                    Spacer()
                    Button("Done") { showing = false }
                }
            }
            .padding(16)
            .frame(width: 290)
        }
    }
}

struct MarkupOverlay: NSViewRepresentable {
    @ObservedObject var pane: Pane
    @ObservedObject var settings: MarkupSettings
    let activate: () -> Void

    func makeNSView(context: Context) -> MarkupCanvas { MarkupCanvas() }

    func updateNSView(_ view: MarkupCanvas, context: Context) {
        view.pane = pane
        view.settings = settings
        view.activate = activate
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

final class MarkupCanvas: NSView {
    static let eraserCursor: NSCursor = {
        let size = NSSize(width: MarkupSettings.eraserWidth + 6, height: MarkupSettings.eraserWidth + 6)
        let image = NSImage(size: size, flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            ring.setLineDash([3, 3], count: 2, phase: 0)
            // Outline the white dashes so they remain visible over light and dark plots.
            NSColor.black.setStroke()
            ring.lineWidth = 3
            ring.stroke()
            NSColor.white.setStroke()
            ring.lineWidth = 1
            ring.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()

    weak var pane: Pane?
    weak var settings: MarkupSettings?
    var activate: (() -> Void)?
    private var stroke: MarkupStroke?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        settings?.tool == .navigate ? nil : super.hitTest(point)
    }

    override func resetCursorRects() {
        switch settings?.tool {
        case .pen: addCursorRect(bounds, cursor: .crosshair)
        case .eraser: addCursorRect(bounds, cursor: Self.eraserCursor)
        default: break
        }
    }

    private func point(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x / max(1, bounds.width), y: point.y / max(1, bounds.height))
    }

    override func mouseDown(with event: NSEvent) {
        guard let settings, settings.tool != .navigate else { return }
        activate?()
        stroke = MarkupStroke(points: [point(for: event)], color: NSColor(settings.color),
                              width: settings.tool == .eraser ? MarkupSettings.eraserWidth : settings.width,
                              erasing: settings.tool == .eraser)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        stroke?.points.append(point(for: event))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard var finished = stroke else { return }
        finished.points.append(point(for: event))
        stroke = nil
        pane?.markup.append(finished)
        needsDisplay = true
    }

    // Keep the plot stationary while drawing; Navigate restores its native gestures.
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: bounds)
        // Erasing must clear only ink, never the image or PDF underneath it.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for mark in (pane?.markup ?? []) + (stroke.map { [$0] } ?? []) {
            guard let first = mark.points.first else { continue }
            context.setBlendMode(mark.erasing ? .clear : .normal)
            context.setStrokeColor(mark.color.cgColor)
            context.setFillColor(mark.color.cgColor)
            context.setLineWidth(mark.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let start = CGPoint(x: first.x * bounds.width, y: first.y * bounds.height)
            context.beginPath()
            context.move(to: start)
            for point in mark.points.dropFirst() {
                context.addLine(to: CGPoint(x: point.x * bounds.width, y: point.y * bounds.height))
            }
            context.strokePath()
            // A click without a drag still leaves a visible dot (or erases one).
            context.fillEllipse(in: CGRect(x: start.x - mark.width / 2, y: start.y - mark.width / 2,
                                           width: mark.width, height: mark.width))
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

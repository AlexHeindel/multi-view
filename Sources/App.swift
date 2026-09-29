import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PaneView: View {
    @ObservedObject var pane: Pane
    @ObservedObject var model: WindowModel
    @State private var dropTarget = false
    private var selected: Bool { model.activeID == pane.id }
    private func activate() { model.activeID = pane.id }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(pane.folder?.lastPathComponent ?? "Choose a folder")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .help(pane.folder?.path ?? "Open or drop a folder of plots")
                    Spacer(minLength: 0)
                    Button { model.chooseFolder(for: pane) } label: { Image(systemName: "folder.badge.plus") }
                        .help("Change this pane’s folder").accessibilityLabel("Change folder")
                }
                HStack(spacing: 5) {
                    Button { model.move(-1, from: pane) } label: { Image(systemName: "chevron.left") }
                        .font(.system(size: 18, weight: .bold)).frame(width: 30, height: 28)
                        .disabled(!model.canMove(-1, from: pane)).help("Previous file (←)").accessibilityLabel("Previous file")
                    Button { model.move(1, from: pane) } label: { Image(systemName: "chevron.right") }
                        .font(.system(size: 18, weight: .bold)).frame(width: 30, height: 28)
                        .disabled(!model.canMove(1, from: pane)).help("Next file (→)").accessibilityLabel("Next file")
                    Button { model.chooseImage(for: pane) } label: {
                        HStack(spacing: 3) {
                            Text(pane.current?.lastPathComponent ?? "Choose Image…")
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                    }
                        .font(.system(size: 12))
                        .help("Choose an image from a folder")
                        .accessibilityLabel("Choose image")
                    Spacer(minLength: 0)
                    Text(pane.files.isEmpty ? "0 / 0" : "\(pane.index + 1) / \(pane.files.count)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .fixedSize()
                    if let pdf = pane.pdf, pdf.pageCount > 1 {
                        Button { activate(); pane.pdfPage -= 1 } label: { Image(systemName: "chevron.up") }
                            .disabled(pane.pdfPage == 0).help("Previous PDF page").accessibilityLabel("Previous PDF page")
                        Text("\(pane.pdfPage + 1)/\(pdf.pageCount)")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Button { activate(); pane.pdfPage += 1 } label: { Image(systemName: "chevron.down") }
                            .disabled(pane.pdfPage + 1 >= pdf.pageCount).help("Next PDF page").accessibilityLabel("Next PDF page")
                    }
                    Button("Fit") { activate(); pane.view(.fit) }.help("Fit to pane (⌘0)")
                        .disabled(pane.raster == nil && pane.nativeImage == nil && pane.pdf == nil)
                    Button(pane.pdf == nil ? "1:1" : "100%") { activate(); pane.view(.actualSize) }
                        .help(pane.pdf == nil ? "One image pixel per screen pixel (⌘1)" : "PDF at 100% (⌘1)")
                        .accessibilityLabel("Actual Size")
                        .disabled(pane.raster == nil && pane.nativeImage == nil && pane.pdf == nil)
                }
                .buttonStyle(.borderless).controlSize(.small)
                .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.bar)
            Divider()
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if pane.indexing {
                    status("Reading folder…", symbol: nil, progress: true)
                } else if pane.loading {
                    status("Loading plot…", symbol: nil, progress: true)
                } else if let error = pane.error {
                    status(error, symbol: "exclamationmark.triangle", progress: false)
                } else if let raster = pane.raster {
                    RasterView(pane: pane, raster: raster, activate: activate)
                } else if let image = pane.nativeImage {
                    NativeImageView(pane: pane, image: image, activate: activate)
                } else if let pdf = pane.pdf {
                    DocumentView(pane: pane, document: pdf, activate: activate)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: pane.folder == nil ? "photo.on.rectangle.angled" : "photo")
                            .font(.system(size: 32, weight: .ultraLight)).foregroundStyle(.secondary)
                        Text(pane.folder == nil ? "Drop a folder here" :
                             model.fileFilter == .all ? "No supported plots in this folder" :
                             "No \(model.fileFilter.rawValue) files in this folder")
                            .font(.system(size: 13, weight: .medium))
                        Text(model.fileFilter == .all ? "PNG, JPEG, TIFF, GIF, SVG & PDF" : "\(model.fileFilter.rawValue) only")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Open Folder…") { model.chooseFolder(for: pane) }
                    }.padding()
                }
                if pane.loadingDetail {
                    VStack { Spacer(); Label("Loading full detail…", systemImage: "arrow.down.circle")
                        .font(.system(size: 11)).padding(8).background(.regularMaterial, in: Capsule()).padding(12) }
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = pane.detailError {
                Text(error).font(.caption).foregroundStyle(.orange).padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(dropTarget ? Color.accentColor : selected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.12),
                          lineWidth: dropTarget ? 2 : 1))
        .background(WideDividerAnchor().allowsHitTesting(false))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { activate() })
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
            model.acceptDrop(providers, into: pane)
        }
    }

    private func status(_ text: String, symbol: String?, progress: Bool) -> some View {
        VStack(spacing: 12) {
            if progress { ProgressView().controlSize(.small) }
            if let symbol { Image(systemName: symbol).font(.title2).foregroundStyle(.secondary) }
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !progress {
                HStack {
                    Button("Refresh") { activate(); pane.refresh() }
                    Button("Open Folder…") { model.chooseFolder(for: pane) }
                }
            }
        }.padding(24)
    }

}

private struct WideDividerAnchor: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                var ancestor = self?.superview
                while let view = ancestor {
                    if let split = view as? NSSplitView, split.dividerStyle != .thick {
                        split.dividerStyle = .thick
                    }
                    ancestor = view.superview
                }
            }
        }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {}
}

struct ContentView: View {
    @ObservedObject var model: WindowModel
    @State private var splitVersion = 0

    var body: some View {
        Group {
            if model.panes.count == 4 {
                VSplitView {
                    HSplitView { pane(0); pane(1) }
                    HSplitView { pane(2); pane(3) }
                }
            } else if model.panes.count > 1 {
                HSplitView {
                    ForEach(model.panes) { PaneView(pane: $0, model: model) }
                }
            } else {
                pane(0)
            }
        }
        .id("\(model.panes.count)-\(splitVersion)")
        .padding(4)
        .frame(minWidth: CGFloat(model.panes.count == 3 ? 900 : model.panes.count > 1 ? 680 : 420), minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { model.chooseFolder() } label: { Label("Open Folder", systemImage: "folder") }
                    .help("Open folder in the selected pane (⌘O)")
                Button { model.addPane() } label: { Label("Add Pane", systemImage: "rectangle.split.2x1") }
                    .disabled(model.panes.count == 4).help("Add a pane (⌘T)")
                Button { model.removePane() } label: { Label("Remove Pane", systemImage: "minus.square") }
                    .disabled(model.panes.count == 1).help("Remove the selected pane")
                Picker("File Type", selection: $model.fileFilter) {
                    ForEach(FileFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                    .pickerStyle(.menu).help("Filter files by format")
                Button { splitVersion += 1 } label: { Label("Equalize Panes", systemImage: "square.split.2x2") }
                    .disabled(model.panes.count == 1).help("Return panes to equal sizes")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $model.linked) { Label("Link Navigation", systemImage: "link") }
                    .toggleStyle(.button)
                    .help("Advance all populated panes together (⌘L). Stops when any pane reaches its boundary.")
                Button { model.active.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.active.folder == nil).help("Refresh the selected folder (⌘R)")
            }
        }
    }

    private func pane(_ index: Int) -> some View { PaneView(pane: model.panes[index], model: model) }
}

struct TabbedContentView: View {
    @ObservedObject var tabs: TabsModel

    var body: some View {
        ContentView(model: tabs.active.model)
            .id(tabs.activeID)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ScrollViewReader { scroll in
                        ScrollView(.horizontal) {
                            HStack(spacing: 4) {
                                ForEach(tabs.tabs) { tab in
                                    HStack(spacing: 6) {
                                        Button("Tab \(tab.number)") { tabs.activeID = tab.id }
                                            .accessibilityLabel("Tab \(tab.number)")
                                            .fixedSize()
                                        if tabs.tabs.count > 1 {
                                            Button { tabs.closeTab(tab.id) } label: {
                                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                                            }
                                            .accessibilityLabel("Close tab \(tab.number)")
                                        }
                                    }
                                    .font(.system(size: 12, weight: tabs.activeID == tab.id ? .semibold : .regular))
                                    .foregroundStyle(tabs.activeID == tab.id ? Color.primary : Color.secondary)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(tabs.activeID == tab.id ? Color.accentColor.opacity(0.16) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .fixedSize()
                                    .id(tab.id)
                                }
                                Button { tabs.addTab() } label: { Image(systemName: "plus") }
                                    .disabled(tabs.tabs.count == 8)
                                    .help("New tab (⌘N)")
                                    .accessibilityLabel("New tab")
                                    .padding(.horizontal, 8)
                                    .id("plus")
                            }
                            .fixedSize()
                            .padding(.horizontal, 8)
                        }
                        .scrollIndicators(.hidden)
                        .frame(width: min(CGFloat(tabs.tabs.count) * 90 + 40, 450), height: 36)
                        .onChange(of: tabs.activeID) { _, id in
                            withAnimation {
                                scroll.scrollTo(id == tabs.tabs.last?.id ? AnyHashable("plus") : AnyHashable(id),
                                                anchor: .trailing)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var tabs: TabsModel?
    var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let model = self?.tabs?.active.model, let window = NSApp.keyWindow,
                  window.identifier?.rawValue == "viewer" || window.title == "Multi-view",
                  window.attachedSheet == nil else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.intersection([.command, .control, .option]).isEmpty else { return event }
            switch event.keyCode {
            case 123: model.move(-1, from: model.active); return nil
            case 124: model.move(1, from: model.active); return nil
            case 48: model.cyclePane(backward: modifiers.contains(.shift)); return nil
            default: return event
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        tabs?.close()
    }
}

#if !CHECKS
@main
struct MultiViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var tabs = TabsModel()

    var body: some Scene {
        Window("Multi-view", id: "viewer") {
            TabbedContentView(tabs: tabs).onAppear {
                delegate.tabs = tabs
                // Folder arguments make Terminal launching and reproducible checks straightforward.
                let folders = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                let model = tabs.active.model
                if model.active.folder == nil {
                    for (index, folder) in folders.prefix(4).enumerated() {
                        if index > 0 { model.addPane() }
                        model.active.open(folder)
                    }
                    model.activeID = model.panes[0].id
                }
            }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { tabs.addTab() }.keyboardShortcut("n").disabled(tabs.tabs.count == 8)
                Button("Close Tab") { tabs.closeTab(tabs.activeID) }.disabled(tabs.tabs.count == 1)
                Divider()
                Button("Open Folder…") { tabs.active.model.chooseFolder() }.keyboardShortcut("o")
                Button("Add Pane") { tabs.active.model.addPane() }.keyboardShortcut("t")
                    .disabled(tabs.active.model.panes.count == 4)
                Button("Remove Pane") { tabs.active.model.removePane() }.keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(tabs.active.model.panes.count == 1)
            }
            CommandMenu("Compare") {
                Toggle("Link Navigation", isOn: Binding(
                    get: { tabs.active.model.linked }, set: { tabs.active.model.linked = $0 }
                )).keyboardShortcut("l")
                Button("Refresh Folder") { tabs.active.model.active.refresh() }.keyboardShortcut("r")
                    .disabled(tabs.active.model.active.folder == nil)
                Divider()
                Button("Fit to Pane") { tabs.active.model.active.view(.fit) }.keyboardShortcut("0")
                Button("Actual Size") { tabs.active.model.active.view(.actualSize) }.keyboardShortcut("1")
                Divider()
                Button("Next Pane") { tabs.active.model.cyclePane() }
                Button("Reveal File in Finder") {
                    if let url = tabs.active.model.active.current { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }.disabled(tabs.active.model.active.current == nil)
            }
        }
    }
}
#endif

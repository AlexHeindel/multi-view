import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PaneView: View {
    @ObservedObject var pane: Pane
    @ObservedObject var model: WindowModel
    let showInfoBars: Bool
    @State private var dropTarget = false
    private var selected: Bool { model.activeID == pane.id }
    private func activate() { model.activeID = pane.id }

    var body: some View {
        VStack(spacing: 0) {
            if showInfoBars {
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
            }
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
    @Binding var appearance: String
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("showInfoBars") private var showInfoBars = true
    @State private var splitVersion = 0

    var body: some View {
        Group {
            if model.stacked && model.panes.count > 1 {
                VSplitView {
                    ForEach(model.panes) { PaneView(pane: $0, model: model, showInfoBars: showInfoBars) }
                }
            } else if model.panes.count == 4 {
                VSplitView {
                    HSplitView { pane(0); pane(1) }
                    HSplitView { pane(2); pane(3) }
                }
            } else if model.panes.count > 1 {
                HSplitView {
                    ForEach(model.panes) { PaneView(pane: $0, model: model, showInfoBars: showInfoBars) }
                }
            } else {
                pane(0)
            }
        }
        .id("\(model.panes.count)-\(model.stacked)-\(splitVersion)")
        .padding(4)
        .frame(minWidth: CGFloat(model.stacked ? 420 : model.panes.count == 3 ? 900 : model.panes.count > 1 ? 680 : 420),
               minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { model.chooseFolder() } label: { Label("Open Folder", systemImage: "folder") }
                    .help("Open folder in the selected pane (⌘O)")
                Button { model.addPane() } label: { Label("Add Pane", systemImage: "plus.square") }
                    .disabled(model.panes.count == 4).help("Add a pane (⌘T)")
                Button { model.removePane() } label: { Label("Remove Pane", systemImage: "minus.square") }
                    .disabled(model.panes.count == 1).help("Remove an empty pane first, or the selected pane")
                Toggle(isOn: $model.stacked) {
                    Label("Stack Panes", systemImage: model.stacked ? "rectangle.split.1x2" : "rectangle.split.2x1")
                }
                    .toggleStyle(.button)
                    .disabled(model.panes.count == 1)
                    .help("Stack panes top to bottom for wide images")
                Toggle(isOn: $showInfoBars) { Label("Pane Info Bars", systemImage: "info.circle") }
                    .toggleStyle(.button)
                    .help(showInfoBars ? "Hide info bars in all panes to give images more room" : "Show info bars in all panes")
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
                Button { appearance = colorScheme == .dark ? "light" : "dark" } label: {
                    Label(colorScheme == .dark ? "Dark Mode" : "Light Mode",
                          systemImage: colorScheme == .dark ? "moon" : "sun.max")
                }
                    .help(colorScheme == .dark ? "Switch to light mode" : "Switch to dark mode")
                Toggle(isOn: $model.linked) { Label("Link Navigation", systemImage: "link") }
                    .toggleStyle(.button)
                    .help("Advance all populated panes together (⌘L). Each folder loops at its ends.")
                Button { model.active.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.active.folder == nil).help("Refresh the selected folder (⌘R)")
            }
        }
    }

    private func pane(_ index: Int) -> some View {
        PaneView(pane: model.panes[index], model: model, showInfoBars: showInfoBars)
    }
}

struct TabbedContentView: View {
    @ObservedObject var tabs: TabsModel
    @AppStorage("appearance") private var appearance = "system"
    @State private var editingID: UUID?
    @State private var draftName = ""
    @State private var confirmingClearAll = false
    @State private var windowWidth: CGFloat = 1100
    @State private var tabContentWidth: CGFloat = 0
    @State private var scrollIndex = 0
    @FocusState private var nameFocused: Bool

    private func beginRename(_ tab: ViewerTab) {
        editingID = tab.id
        draftName = tab.name ?? ""
    }

    private func finishRename() {
        guard let editingID else { return }
        tabs.renameTab(editingID, to: draftName)
        self.editingID = nil
        nameFocused = false
    }

    private func revealActiveTab(in scroll: ScrollViewProxy) {
        let last = tabs.activeID == tabs.tabs.last?.id
        scrollIndex = last ? tabs.tabs.count : tabs.tabs.firstIndex(where: { $0.id == tabs.activeID }) ?? 0
        scroll.scrollTo(last ? AnyHashable("plus") : AnyHashable(tabs.activeID), anchor: .trailing)
    }

    private func scrollTabs(_ direction: Int, in scroll: ScrollViewProxy) {
        scrollIndex = min(max(scrollIndex + direction, 0), tabs.tabs.count)
        let target: AnyHashable = scrollIndex == tabs.tabs.count ? AnyHashable("plus") : AnyHashable(tabs.tabs[scrollIndex].id)
        withAnimation { scroll.scrollTo(target, anchor: direction < 0 ? .leading : .trailing) }
    }

    var body: some View {
        ContentView(model: tabs.active.model, appearance: $appearance)
            .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
            .id(tabs.activeID)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { windowWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in windowWidth = width }
                }
            }
            .onChange(of: nameFocused) { _, focused in
                if !focused { finishRename() }
            }
            .alert("Clear all tabs and panes?", isPresented: $confirmingClearAll) {
                Button("Clear All", role: .destructive) {
                    editingID = nil
                    nameFocused = false
                    tabs.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the saved session and returns to one blank tab and pane. Your files and folders are kept.")
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { confirmingClearAll = true } label: { Label("Clear All", systemImage: "trash") }
                        .help("Clear the saved session and return to one blank tab and pane")
                }
                ToolbarItem(placement: .principal) {
                    ScrollViewReader { scroll in
                        let availableWidth = max(280, windowWidth - 860)
                        let overflowing = tabContentWidth > availableWidth
                        HStack(spacing: 0) {
                            if overflowing {
                                Button { scrollTabs(-1, in: scroll) } label: { Image(systemName: "chevron.left") }
                                    .disabled(scrollIndex == 0)
                                    .help("Scroll tabs left")
                                    .accessibilityLabel("Scroll tabs left")
                                    .frame(width: 22, height: 36)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(tabs.tabs) { tab in
                                        HStack(spacing: 6) {
                                            if editingID == tab.id {
                                                TextField("Name", text: $draftName)
                                                    .textFieldStyle(.roundedBorder)
                                                    .frame(width: 120)
                                                    .focused($nameFocused)
                                                    .onAppear { nameFocused = true }
                                                    .onSubmit { finishRename() }
                                                    .onExitCommand {
                                                        editingID = nil
                                                        nameFocused = false
                                                    }
                                            } else {
                                                Button { tabs.activeID = tab.id } label: {
                                                    Text(tab.title).lineLimit(1).frame(maxWidth: 160)
                                                }
                                                .accessibilityLabel(tab.title)
                                                .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(tab) })
                                            }
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
                                        .help("Double-click the tab name to rename; drag to reorder")
                                        .draggable(tab.id.uuidString)
                                        .dropDestination(for: String.self) { items, _ in
                                            guard let source = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                                            return tabs.moveTab(source, to: tab.id)
                                        }
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
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear
                                            .onAppear { tabContentWidth = geometry.size.width }
                                            .onChange(of: geometry.size.width) { _, width in tabContentWidth = width }
                                    }
                                }
                                .background(TabWheelScrollView { progress in
                                    let index = Int((progress * CGFloat(tabs.tabs.count)).rounded())
                                    if index != scrollIndex { scrollIndex = index }
                                })
                            }
                            .frame(width: min(max(40, tabContentWidth), availableWidth - (overflowing ? 44 : 0)), height: 36)
                            if overflowing {
                                Button { scrollTabs(1, in: scroll) } label: { Image(systemName: "chevron.right") }
                                    .disabled(scrollIndex == tabs.tabs.count)
                                    .help("Scroll tabs right")
                                    .accessibilityLabel("Scroll tabs right")
                                    .frame(width: 22, height: 36)
                            }
                        }
                        .onAppear { revealActiveTab(in: scroll) }
                        .onChange(of: windowWidth) { _, _ in revealActiveTab(in: scroll) }
                        .onChange(of: tabs.tabs.map(\.id)) { _, _ in revealActiveTab(in: scroll) }
                        .onChange(of: tabs.activeID) { _, _ in
                            withAnimation { revealActiveTab(in: scroll) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
    }
}

private struct TabWheelScrollView: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    final class View: NSView {
        private var wheelMonitor: Any?
        var onScroll: (CGFloat) -> Void = { _ in }

        private func reportPosition() {
            guard let scrollView = enclosingScrollView, let document = scrollView.documentView else { return }
            let distance = max(0, document.frame.width - scrollView.contentView.bounds.width)
            onScroll(distance == 0 ? 0 : scrollView.contentView.bounds.minX / distance)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
            guard window != nil else { return }
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      let scrollView = self.enclosingScrollView,
                      let document = scrollView.documentView else { return event }
                let clip = scrollView.contentView
                guard clip.bounds.contains(clip.convert(event.locationInWindow, from: nil)),
                      document.frame.width > clip.bounds.width else { return event }
                if abs(event.scrollingDeltaX) >= 0.5 {
                    DispatchQueue.main.async { [weak self] in self?.reportPosition() }
                    return event
                }
                guard event.scrollingDeltaY != 0 else { return event }
                let step = event.hasPreciseScrollingDeltas ? 1.0 : 40.0
                let x = min(max(clip.bounds.minX - event.scrollingDeltaY * step, 0),
                            document.frame.width - clip.bounds.width)
                clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
                scrollView.reflectScrolledClipView(clip)
                self.reportPosition()
                return nil
            }
        }

        deinit { if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) } }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.onScroll = onScroll
        return view
    }
    func updateNSView(_ view: View, context: Context) { view.onScroll = onScroll }
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
            if window.firstResponder is NSTextView { return event }
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
    @StateObject private var tabs = TabsModel(defaults: .standard)
    @AppStorage("appearance") private var appearance = "system"

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
                Button("Use System Appearance") { appearance = "system" }
                    .disabled(appearance == "system")
                Divider()
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

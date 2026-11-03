import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PaneView: View {
    @ObservedObject var pane: Pane
    @ObservedObject var model: WindowModel
    @EnvironmentObject private var markupSettings: MarkupSettings
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
                } else if let error = pane.error {
                    status(error, symbol: "exclamationmark.triangle", progress: false)
                } else if let raster = pane.raster {
                    RasterView(pane: pane, raster: raster, activate: activate)
                } else if let image = pane.nativeImage {
                    NativeImageView(pane: pane, image: image, activate: activate)
                } else if let pdf = pane.pdf {
                    DocumentView(pane: pane, document: pdf, activate: activate)
                } else if pane.loading {
                    status("Loading plot…", symbol: nil, progress: true)
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
            .overlay { MarkupOverlay(pane: pane, settings: markupSettings, activate: activate) }
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
    let wipeMarkup: () -> Void
    let clearAll: () -> Void
    @EnvironmentObject private var markupSettings: MarkupSettings
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
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("File Type", selection: $model.fileFilter) {
                    ForEach(FileFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                    .pickerStyle(.menu).help("Filter files by format")
                Button { model.chooseFolder() } label: { Label("Open Folder", systemImage: "folder") }
                    .help("Open folder in the selected pane (⌘O)")
                Button { model.active.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.active.folder == nil).help("Refresh the selected folder (⌘R)")
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
                Button { splitVersion += 1 } label: { Label("Equalize Panes", systemImage: "square.split.2x2") }
                    .disabled(model.panes.count == 1).help("Return panes to equal sizes")
                Toggle(isOn: $showInfoBars) { Label("Pane Info Bars", systemImage: "info.circle") }
                    .toggleStyle(.button)
                    .help(showInfoBars ? "Hide info bars in all panes to give images more room" : "Show info bars in all panes")
                Toggle(isOn: $model.linked) { Label("Chain Navigation", systemImage: "link") }
                    .toggleStyle(.button)
                    .help("Advance all populated panes together (⌘L). Each folder loops at its ends.")
                MarkupControls(settings: markupSettings, wipeAll: wipeMarkup)
                Button { appearance = colorScheme == .dark ? "light" : "dark" } label: {
                    Label(colorScheme == .dark ? "Dark Mode" : "Light Mode",
                          systemImage: colorScheme == .dark ? "moon" : "sun.max")
                }
                    .help(colorScheme == .dark ? "Switch to light mode" : "Switch to dark mode")
                Button(action: clearAll) { Label("Clear All", systemImage: "trash") }
                    .help("Clear the saved session and return to one blank tab and pane")
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
    @State private var confirmingClearAll = false
    @State private var windowWidth: CGFloat = 1100

    var body: some View {
        ContentView(model: tabs.active.model, appearance: $appearance, wipeMarkup: tabs.wipeMarkup,
                    clearAll: { confirmingClearAll = true })
            .environmentObject(tabs.markupSettings)
            .id(tabs.activeID)
            .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { windowWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in windowWidth = width }
                }
            }
            .alert("Clear all tabs and panes?", isPresented: $confirmingClearAll) {
                Button("Clear All", role: .destructive) {
                    tabs.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the saved session and returns to one blank tab and pane. Your files and folders are kept.")
            }
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) {
                        Text("Multi-view").font(.headline).fixedSize()
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) {
                        Text("Multi-view").font(.headline).fixedSize()
                    }
                }
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.flexible, placement: .primaryAction)
                } else {
                    ToolbarItem(placement: .primaryAction) { Spacer() }
                }
                ToolbarItem(placement: .primaryAction) {
                    NativeTabBar(tabs: tabs)
                        .frame(width: max(120, windowWidth - 766), height: 40)
                        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                }
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .primaryAction) {
                        Color.clear.frame(width: 38, height: 1).accessibilityHidden(true)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Color.clear.frame(width: 38, height: 1).accessibilityHidden(true)
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
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { tabs.addTab() }.keyboardShortcut("n").disabled(tabs.tabs.count >= TabsModel.maxTabs)
                Button("Close Tab") { tabs.closeTab(tabs.activeID) }.disabled(tabs.tabs.count == 1)
                Button("Previous Tab") { tabs.moveTabSelection(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(tabs.activeID == tabs.tabs.first?.id)
                Button("Next Tab") { tabs.moveTabSelection(1) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(tabs.activeID == tabs.tabs.last?.id)
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
                Toggle("Chain Navigation", isOn: Binding(
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

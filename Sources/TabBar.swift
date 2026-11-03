import AppKit
import SwiftUI

struct NativeTabBar: NSViewRepresentable {
    @ObservedObject var tabs: TabsModel

    func makeNSView(context: Context) -> TabBarView { TabBarView() }
    func updateNSView(_ view: TabBarView, context: Context) { view.update(tabs) }
}

enum TabBarItem: Hashable {
    case tab(UUID), group(UUID)
}

/// Native mouse tracking keeps drag previews independent of image loading and SwiftUI layout.
final class TabBarView: NSView {
    private let scroll = TabStripScrollView()
    private let strip = FlippedView()
    private let previous = NSButton()
    private let next = NSButton()
    private let add = NSButton()
    private(set) var items: [TabBarItem: TabBarItemView] = [:]
    private(set) var groupUnderlines: [UUID: TabGroupUnderline] = [:]
    private var order: [TabBarItem] = []
    private var positions: [TabBarItem: NSRect] = [:]
    private weak var tabs: TabsModel?
    private var previousSelection: TabBarItem?
    private var previousCount = 0
    private var snapshot = ""
    private var dragging: TabBarItem?
    private var dragOffset: CGFloat = 0
    private var dragWindowPoint = NSPoint.zero
    private var previewTabs: [ViewerTab] = []
    private var destination: (index: Int, groupID: UUID?)?
    private var autoScroll: Timer?
    private var editor: NSTextField?
    private var editing: TabBarItem?
    private var deletionAlert: NSAlert?
    private var contextMenuMonitor: Any?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = strip
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        addSubview(scroll)
        for (button, symbol, label, action) in [
            (previous, "chevron.left", "Scroll tabs left", #selector(scrollLeft)),
            (next, "chevron.right", "Scroll tabs right", #selector(scrollRight)),
            (add, "plus", "New tab (⌘N)", #selector(addTab))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .inline
            button.isBordered = false
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let contextMenuMonitor { NSEvent.removeMonitor(contextMenuMonitor) }
        autoScroll?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func update(_ tabs: TabsModel) {
        self.tabs = tabs
        add.isEnabled = tabs.tabs.count < TabsModel.maxTabs
        // Pane notifications also reach this view; only tab metadata needs a strip update.
        let state = tabs.tabs.map { "\($0.id):\($0.title):\($0.groupID?.uuidString ?? "")" }.joined(separator: "|")
            + tabs.groups.map { "\($0.id):\($0.title):\($0.collapsed):\($0.color?.rawValue ?? "")" }.joined(separator: "|")
            + tabs.activeID.uuidString
        guard state != snapshot else { return }
        if dragging != nil { endDrag(commit: false) }
        snapshot = state
        let reveal = previousSelection != selection || tabs.tabs.count > previousCount
        previousSelection = selection
        previousCount = tabs.tabs.count
        refresh(animate: window != nil)
        if reveal { revealSelection() }
    }

    override func layout() {
        super.layout()
        previous.frame = NSRect(x: 4, y: 5, width: 24, height: 30)
        add.frame = NSRect(x: max(28, bounds.width - 34), y: 5, width: 28, height: 30)
        next.frame = NSRect(x: max(28, bounds.width - 60), y: 5, width: 24, height: 30)
        let width = max(1, bounds.width - 90)
        let changed = scroll.frame.width != width
        scroll.frame = NSRect(x: 30, y: 0, width: width, height: 40)
        layoutItems(animate: false)
        if changed, dragging == nil { revealSelection() }
    }

    private func refresh(animate: Bool) {
        guard let tabs else { return }
        let allTabs = dragging == nil ? tabs.tabs : previewTabs
        for id in Array(groupUnderlines.keys) where !tabs.groups.contains(where: { $0.id == id }) {
            groupUnderlines.removeValue(forKey: id)?.removeFromSuperview()
        }
        for group in tabs.groups {
            let underline = groupUnderlines[group.id] ?? TabGroupUnderline()
            if groupUnderlines[group.id] == nil {
                groupUnderlines[group.id] = underline
                strip.addSubview(underline, positioned: .below, relativeTo: nil)
            }
            underline.color = group.color ?? .gold
            underline.needsDisplay = true
        }
        let live = Set(tabs.tabs.map { TabBarItem.tab($0.id) } + tabs.groups.map { .group($0.id) })
        for key in Array(items.keys) where !live.contains(key) {
            if editing == key { finishRename(save: false) }
            items.removeValue(forKey: key)?.removeFromSuperview()
        }
        order = []
        var seen = Set<UUID>()
        for tab in allTabs {
            if let groupID = tab.groupID, let group = tabs.groups.first(where: { $0.id == groupID }) {
                if seen.insert(groupID).inserted {
                    let key = TabBarItem.group(groupID)
                    let count = allTabs.filter { $0.groupID == groupID }.count
                    configure(key, title: group.title, selected: allTabs.contains { $0.groupID == groupID && $0.id == tabs.activeID },
                              groupID: groupID, collapsed: group.collapsed, count: count)
                    order.append(key)
                }
                if group.collapsed { continue }
            }
            let key = TabBarItem.tab(tab.id)
            configure(key, title: tab.title, selected: tab.id == tabs.activeID,
                      groupID: tab.groupID, collapsed: false, count: 0)
            order.append(key)
        }
        for (key, item) in items { item.isHidden = !order.contains(key) && key != dragging }
        layoutItems(animate: animate)
    }

    private func configure(_ key: TabBarItem, title: String, selected: Bool, groupID: UUID?, collapsed: Bool, count: Int) {
        let item: TabBarItemView
        if let existing = items[key] { item = existing }
        else {
            item = TabBarItemView(key: key, bar: self)
            items[key] = item
            strip.addSubview(item)
        }
        item.title = title
        item.selected = selected
        item.groupID = groupID
        item.groupColor = groupID.flatMap { id in tabs?.groups.first { $0.id == id }?.color }
        item.collapsed = collapsed
        item.count = count
        item.isRenaming = editing == key
        item.close.isHidden = editing == key || count > 0 || tabs?.tabs.count == 1
        item.needsDisplay = true
        item.toolTip = count > 0
            ? "\(title) — Click to expand or collapse; drag when collapsed to move the group; right-click for options; double-click the name to rename"
            : "\(title) — Double-click to rename; right-click for tab options"
        item.setAccessibilityLabel(count > 0 ? "\(title), \(count) tabs, \(collapsed ? "collapsed" : "expanded")" : title)
        item.setAccessibilityValue(selected ? "Selected" : "")
    }

    private func layoutItems(animate: Bool) {
        var x: CGFloat = 6
        positions = [:]
        for key in order {
            guard let item = items[key] else { continue }
            let width = editing == key ? 180 : item.preferredWidth
            positions[key] = NSRect(x: x, y: 4, width: width, height: 32)
            x += width + 4
        }
        strip.frame.size = NSSize(width: max(scroll.contentSize.width, x + 6), height: 40)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for key in order where key != dragging {
                guard let item = items[key], let frame = positions[key] else { continue }
                if context.duration > 0, item.frame.width > 0 { item.animator().frame = frame }
                else { item.frame = frame }
            }
            for (id, underline) in groupUnderlines {
                let members = order.filter { items[$0]?.groupID == id }
                guard let first = members.first.flatMap({ positions[$0] }),
                      let last = members.last.flatMap({ positions[$0] }) else {
                    underline.isHidden = true
                    continue
                }
                underline.isHidden = false
                let frame = NSRect(x: first.minX + 8, y: 37, width: last.maxX - first.minX - 16, height: 2)
                underline.frame = frame
            }
        }
        if let editor, let editing, let item = items[editing] {
            editor.frame = NSRect(x: 8, y: 4, width: item.bounds.width - 16, height: 24)
        }
        scrolled()
    }

    private var selection: TabBarItem? {
        guard let tabs else { return nil }
        if let groupID = tabs.active.groupID, tabs.groups.first(where: { $0.id == groupID })?.collapsed == true {
            return .group(groupID)
        }
        return .tab(tabs.activeID)
    }

    private func revealSelection() {
        guard let key = selection else { return }
        if let frame = positions[key] { strip.scrollToVisible(frame.insetBy(dx: -4, dy: 0)) }
        scrolled()
    }

    @objc private func scrolled() {
        let clip = scroll.contentView.bounds
        previous.isEnabled = clip.minX > 1
        next.isEnabled = clip.maxX < strip.bounds.width - 1
    }

    private func scrollBy(_ delta: CGFloat) {
        let clip = scroll.contentView
        let x = min(max(clip.bounds.minX + delta, 0), max(0, strip.bounds.width - clip.bounds.width))
        clip.scroll(to: NSPoint(x: x, y: 0))
        scroll.reflectScrolledClipView(clip)
        scrolled()
    }

    @objc private func scrollLeft() { scrollBy(-max(100, scroll.contentSize.width * 0.7)) }
    @objc private func scrollRight() { scrollBy(max(100, scroll.contentSize.width * 0.7)) }
    @objc private func addTab() { finishRename(save: true); tabs?.addTab() }

    func activate(_ key: TabBarItem) {
        finishRename(save: true)
        switch key {
        case .tab(let id): tabs?.activeID = id
        case .group(let id): tabs?.toggleGroup(id)
        }
    }

    func toggleGroup(_ id: UUID) {
        finishRename(save: true)
        tabs?.toggleGroup(id)
    }

    func showMenu(for key: TabBarItem) {
        guard let item = items[key], !item.isHidden else { return }
        menu(for: key).popUp(positioning: nil, at: NSPoint(x: 0, y: item.bounds.maxY), in: item)
    }

    private func confirmDeleteGroup(_ id: UUID) {
        guard deletionAlert == nil, let tabs, let group = tabs.groups.first(where: { $0.id == id }),
              let window, window.attachedSheet == nil else { return }
        finishRename(save: true)
        let alert = NSAlert()
        alert.messageText = "Delete tab group “\(group.title)”?"
        alert.informativeText = "The tabs in this group will stay open in the main tab strip. Their names, panes, and contents will be kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Tab Group").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        deletionAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak tabs] response in
            self?.deletionAlert = nil
            if response == .alertFirstButtonReturn { tabs?.ungroup(id) }
        }
    }

    func close(_ key: TabBarItem) {
        guard case .tab(let id) = key else { return }
        finishRename(save: true)
        tabs?.closeTab(id)
    }

    func beginRename(_ key: TabBarItem) {
        guard let tabs, let item = items[key] else { return }
        finishRename(save: true)
        editing = key
        item.isRenaming = true
        let field = NSTextField()
        switch key {
        case .tab(let id): field.stringValue = tabs.tabs.first { $0.id == id }?.name ?? ""
        case .group(let id): field.stringValue = tabs.groups.first { $0.id == id }?.name ?? ""
        }
        field.placeholderString = "Name"
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.focusRingType = .exterior
        field.setAccessibilityLabel("Name")
        editor = field
        item.addSubview(field)
        item.close.isHidden = true
        layoutItems(animate: false)
        item.scrollToVisible(item.bounds)
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, self.editor === field else { return }
            field.selectText(nil)
        }
    }

    private func finishRename(save: Bool) {
        guard let editor, let editing else { return }
        let name = editor.currentEditor()?.string ?? editor.stringValue
        self.editor = nil
        self.editing = nil
        items[editing]?.isRenaming = false
        editor.delegate = nil
        editor.removeFromSuperview()
        if save {
            switch editing {
            case .tab(let id): tabs?.renameTab(id, to: name)
            case .group(let id): tabs?.renameGroup(id, to: name)
            }
        }
        refresh(animate: false)
    }

    func menu(for key: TabBarItem) -> NSMenu {
        let menu = NSMenu()
        func action(_ title: String, _ run: @escaping () -> Void) {
            let item = TabMenuItem(title: title, run: run)
            menu.addItem(item)
        }
        action("Rename…") { [weak self] in self?.beginRename(key) }
        guard let tabs else { return menu }
        switch key {
        case .tab(let id):
            action("Add to New Group") { [weak self] in
                guard let self, let groupID = self.tabs?.createGroup(for: id), let model = self.tabs else { return }
                self.update(model)
                self.beginRename(.group(groupID))
            }
            if !tabs.groups.isEmpty {
                let parent = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for group in tabs.groups {
                    let item = TabMenuItem(title: group.title) { [weak self] in self?.tabs?.assignTab(id, to: group.id) }
                    item.state = tabs.tabs.first { $0.id == id }?.groupID == group.id ? .on : .off
                    submenu.addItem(item)
                }
                parent.submenu = submenu
                menu.addItem(parent)
            }
            if tabs.tabs.first(where: { $0.id == id })?.groupID != nil {
                action("Remove from Group") { [weak self] in self?.tabs?.assignTab(id, to: nil) }
            }
            if tabs.tabs.count > 1 { action("Close Tab") { [weak self] in self?.close(key) } }
        case .group(let id):
            let colorMenu = NSMenu()
            for color in TabGroupColor.allCases {
                let item = TabMenuItem(title: "\(color.name) (\(color.rawValue))") { [weak self] in
                    self?.tabs?.setGroupColor(id, to: color)
                }
                item.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                    let swatch = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
                    color.nsColor.setFill()
                    swatch.fill()
                    NSColor.labelColor.withAlphaComponent(0.3).setStroke()
                    swatch.stroke()
                    return true
                }
                item.state = tabs.groups.first { $0.id == id }?.color == color ? .on : .off
                colorMenu.addItem(item)
            }
            let changeColor = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
            changeColor.submenu = colorMenu
            menu.addItem(changeColor)
            action(tabs.groups.first { $0.id == id }?.collapsed == true ? "Expand Group" : "Collapse Group") { [weak self] in
                self?.tabs?.toggleGroup(id)
            }
            if tabs.tabs.count < TabsModel.maxTabs {
                action("New Tab in Group") { [weak self] in self?.tabs?.addTab(in: id) }
            }
            action("Delete Tab Group…") { [weak self] in self?.confirmDeleteGroup(id) }
        }
        return menu
    }

    func drag(_ key: TabBarItem, event: NSEvent, start: NSPoint) {
        guard let tabs, let item = items[key] else { return }
        if case .group(let id) = key, tabs.groups.first(where: { $0.id == id })?.collapsed != true { return }
        if dragging == nil {
            finishRename(save: true)
            dragging = key
            previewTabs = tabs.tabs
            dragOffset = strip.convert(start, from: nil).x - item.frame.minX
            strip.addSubview(item, positioned: .above, relativeTo: nil)
            item.alphaValue = 0.85
            window?.makeFirstResponder(self)
            autoScroll = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.dragScroll() }
            RunLoop.main.add(autoScroll!, forMode: .common)
        }
        dragWindowPoint = event.locationInWindow
        updateDrag()
    }

    private func dragScroll() {
        guard dragging != nil else { return }
        let x = scroll.convert(dragWindowPoint, from: nil).x
        let edge: CGFloat = 36
        let delta: CGFloat = x < edge ? -min(12, (edge - x) / 3) :
            x > scroll.bounds.width - edge ? min(12, (x - scroll.bounds.width + edge) / 3) : 0
        if delta != 0 { scrollBy(delta); updateDrag() }
    }

    private func updateDrag() {
        guard let dragging, let tabs, let item = items[dragging] else { return }
        let point = strip.convert(dragWindowPoint, from: nil)
        let x = point.x - dragOffset
        // Cross a neighbor's center before changing slots; the slot itself stays stable under the pointer.
        let center = x + item.frame.width / 2
        let others = order.filter { $0 != dragging }
        switch dragging {
        case .tab(let id):
            let target = others.first { (positions[$0]?.midX ?? 0) > center }
            let remaining = tabs.tabs.filter { $0.id != id }
            let index: Int
            let groupID: UUID?
            switch target {
            case .tab(let id):
                index = remaining.firstIndex { $0.id == id } ?? remaining.count
                groupID = remaining.first { $0.id == id }?.groupID
            case .group(let id):
                index = remaining.firstIndex { $0.groupID == id }
                    ?? min(tabs.tabs.firstIndex { $0.groupID == id } ?? remaining.count, remaining.count)
                groupID = nil
            case nil:
                index = remaining.count
                groupID = remaining.last?.groupID
            }
            // A collapsed header accepts a tab on its right half, without expanding the group.
            let preceding = others.last { (positions[$0]?.midX ?? .infinity) <= center }
            var insertion = index
            var group = groupID
            if case .group(let id) = preceding {
                group = id
                insertion = remaining.firstIndex { $0.groupID == id } ?? index
            }
            if destination?.index != insertion || destination?.groupID != group {
                destination = (insertion, group)
                previewTabs = remaining
                var moved = tabs.tabs.first { $0.id == id }!
                moved.groupID = group
                previewTabs.insert(moved, at: insertion)
                refresh(animate: true)
            }
        case .group(let id):
            let members = tabs.tabs.filter { $0.groupID == id }
            let remaining = tabs.tabs.filter { $0.groupID != id }
            var insertion = remaining.count
            // Other groups are indivisible drop targets, including their expanded tabs.
            for key in others {
                let index: Int
                let frame: NSRect
                switch key {
                case .group(let otherID):
                    guard let first = remaining.firstIndex(where: { $0.groupID == otherID }) else { continue }
                    index = first
                    frame = others.filter { items[$0]?.groupID == otherID }
                        .compactMap { positions[$0] }.reduce(.null) { $0.union($1) }
                case .tab(let tabID):
                    guard let first = remaining.firstIndex(where: { $0.id == tabID }),
                          remaining[first].groupID == nil, let position = positions[key] else { continue }
                    index = first
                    frame = position
                }
                if center < frame.midX { insertion = index; break }
            }
            if destination?.index != insertion {
                destination = (insertion, nil)
                previewTabs = remaining
                previewTabs.insert(contentsOf: members, at: insertion)
                refresh(animate: true)
            }
        }
        item.frame.origin.x = min(max(x, scroll.contentView.bounds.minX), max(0, strip.bounds.width - item.frame.width))
        item.frame.origin.y = 4
        if case .group(let id) = dragging {
            groupUnderlines[id]?.frame = NSRect(x: item.frame.minX + 8, y: 37, width: item.frame.width - 16, height: 2)
        }
    }

    func endDrag(commit: Bool) {
        guard let dragging else { return }
        autoScroll?.invalidate()
        autoScroll = nil
        self.dragging = nil
        items[dragging]?.alphaValue = 1
        if commit, let destination {
            switch dragging {
            case .tab(let id): tabs?.insertTab(id, at: destination.index, in: destination.groupID)
            case .group(let id): tabs?.insertGroup(id, at: destination.index)
            }
        }
        destination = nil
        previewTabs = []
        refresh(animate: true)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { endDrag(commit: false) }
        else { super.keyDown(with: event) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let contextMenuMonitor { NSEvent.removeMonitor(contextMenuMonitor) }
        contextMenuMonitor = nil
        guard window != nil else { endDrag(commit: false); return }
        // Toolbar context menus otherwise take precedence over the embedded tab views.
        contextMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  self.scroll.bounds.contains(self.scroll.convert(event.locationInWindow, from: nil)) else { return event }
            let point = self.strip.convert(event.locationInWindow, from: nil)
            guard let (key, _) = self.items.first(where: { !$0.value.isHidden && $0.value.frame.contains(point) }),
                  key != self.editing else { return event }
            DispatchQueue.main.async { [weak self] in self?.showMenu(for: key) }
            return nil
        }
    }
}

extension TabBarView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) { finishRename(save: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishRename(save: false)
        } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishRename(save: true)
        } else { return false }
        window?.makeFirstResponder(nil)
        return true
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class TabGroupUnderline: NSView {
    var color = TabGroupColor.gold
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        color.nsColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1).fill()
    }
}

private final class TabStripScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let documentView else { return }
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 24
        let x = min(max(contentView.bounds.minX - delta * scale, 0),
                    max(0, documentView.bounds.width - contentView.bounds.width))
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

private final class TabMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { run() }
}

final class TabBarItemView: NSView {
    let key: TabBarItem
    private weak var bar: TabBarView?
    let close = NSButton()
    var title = ""
    var selected = false
    var groupID: UUID?
    var groupColor: TabGroupColor?
    var collapsed = false
    var count = 0
    var isRenaming = false { didSet { needsDisplay = true } }
    private var start: NSPoint?
    private var moved = false
    override var isFlipped: Bool { true }

    var preferredWidth: CGFloat {
        let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        return min(220, max(90, ceil(textWidth) + (count > 0 ? 56 : 42)))
    }

    init(key: TabBarItem, bar: TabBarView) {
        self.key = key
        self.bar = bar
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        close.isBordered = false
        close.bezelStyle = .inline
        close.target = self
        close.action = #selector(closeTab)
        close.setAccessibilityLabel("Close tab")
        addSubview(close)
        var actions = [NSAccessibilityCustomAction(name: "Rename", target: self, selector: #selector(rename))]
        if case .tab = key {
            actions.append(NSAccessibilityCustomAction(name: "Close tab", target: self, selector: #selector(closeAccessibly)))
        } else {
            actions.append(NSAccessibilityCustomAction(name: "Expand or Collapse Group", target: self, selector: #selector(toggleGroupAccessibly)))
        }
        setAccessibilityCustomActions(actions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        close.frame = NSRect(x: bounds.width - 24, y: 8, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let group = count > 0
        let color = groupColor?.nsColor ?? .controlAccentColor
        let fill = group ? color : selected ? color.withAlphaComponent(0.22) : NSColor.labelColor.withAlphaComponent(0.04)
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        fill.setFill()
        background.fill()
        if group && selected {
            NSColor.white.withAlphaComponent(0.4).setStroke()
            background.stroke()
        }
        guard !isRenaming else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: group ? NSColor.white : selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let left: CGFloat = group ? 24 : 10
        (title as NSString).draw(in: NSRect(x: left, y: 8, width: bounds.width - left - (group ? 30 : 28), height: 17),
                                withAttributes: attributes)
        if group {
            let chevron = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.white]))
            chevron?.draw(in: NSRect(x: 8, y: 11, width: 10, height: 10))
            ("\(count)" as NSString).draw(in: NSRect(x: bounds.width - 25, y: 9, width: 23, height: 16),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.8)])
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
        moved = false
        if event.clickCount == 2 {
            if count == 0 || convert(event.locationInWindow, from: nil).x >= 24 { bar?.beginRename(key) }
            start = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        if !moved, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) < 4 { return }
        moved = true
        if case .group = key, !collapsed { return }
        bar?.drag(key, event: event, start: start)
    }

    override func mouseUp(with event: NSEvent) {
        if moved { bar?.endDrag(commit: true) }
        else if start != nil { bar?.activate(key) }
        start = nil
        moved = false
    }

    override func menu(for event: NSEvent) -> NSMenu? { bar?.menu(for: key) }
    override func accessibilityPerformPress() -> Bool { bar?.activate(key); return true }
    override func accessibilityPerformShowMenu() -> Bool {
        guard let bar else { return false }
        bar.showMenu(for: key)
        return true
    }
    @objc private func toggleGroupAccessibly() -> Bool {
        guard case .group(let id) = key else { return false }
        bar?.toggleGroup(id)
        return true
    }
    @objc private func rename() -> Bool { bar?.beginRename(key); return true }
    @objc private func closeAccessibly() -> Bool { bar?.close(key); return true }
    @objc private func closeTab() { bar?.close(key) }
}

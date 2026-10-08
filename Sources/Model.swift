import AppKit
import Combine
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum FileFilter: String, CaseIterable, Codable {
    case png = "PNG", jpeg = "JPEG", tiff = "TIFF", gif = "GIF", svg = "SVG", pdf = "PDF", all = "All"

    var extensions: [String] {
        switch self {
        case .png: return ["png"]
        case .jpeg: return ["jpg", "jpeg"]
        case .tiff: return ["tif", "tiff"]
        case .gif: return ["gif"]
        case .svg: return ["svg"]
        case .pdf: return ["pdf"]
        case .all: return ["png", "jpg", "jpeg", "tif", "tiff", "gif", "svg", "pdf"]
        }
    }

    func includes(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    var allowedTypes: [UTType] {
        switch self {
        case .png: return [.png]
        case .jpeg: return [.jpeg]
        case .tiff: return [.tiff]
        case .gif: return [.gif]
        case .svg: return [.svg]
        case .pdf: return [.pdf]
        case .all: return [.png, .jpeg, .tiff, .gif, .svg, .pdf]
        }
    }
}

enum Catalog {
    static let extensions = Set(FileFilter.all.extensions)

    static func files(in folder: URL, cancelled: () -> Bool = { false }) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var files: [URL] = []
        for url in urls {
            if cancelled() { return [] }
            guard extensions.contains(url.pathExtension.lowercased()),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            files.append(url)
        }
        return files.sorted {
            let comparison = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            return comparison == .orderedSame
                ? $0.lastPathComponent < $1.lastPathComponent : comparison == .orderedAscending
        }
    }

    static func selection(in files: [URL], preserving url: URL?, oldIndex: Int) -> Int {
        if let url, let index = files.firstIndex(of: url) { return index }
        return min(max(0, oldIndex), max(0, files.count - 1))
    }

    static func canMove(_ positions: [(index: Int, count: Int)], by step: Int) -> Bool {
        step != 0 && positions.contains { $0.count > 1 }
            && positions.allSatisfy { $0.index >= 0 && $0.index < $0.count }
    }
}

final class Raster {
    let image: CGImage
    let size: CGSize
    let fullDetail: Bool
    var cost: Int { image.bytesPerRow * image.height }
    init(image: CGImage, size: CGSize, fullDetail: Bool) {
        self.image = image
        self.size = size
        self.fullDetail = fullDetail
    }
}

enum ViewerError: LocalizedError {
    case unreadable
    case lockedPDF
    var errorDescription: String? {
        switch self {
        case .unreadable: return "This file could not be opened. It may be damaged or unreadable."
        case .lockedPDF: return "This PDF is password protected. Open it in Preview to unlock it."
        }
    }
}

final class Loader {
    static let shared = Loader()
    let decoding = OperationQueue()
    let indexing = OperationQueue()
    let previews = NSCache<NSString, Raster>()

    private init() {
        decoding.name = "Multi-view decoding"
        decoding.maxConcurrentOperationCount = 2
        decoding.qualityOfService = .userInitiated
        indexing.name = "Multi-view folder indexing"
        indexing.maxConcurrentOperationCount = 2
        indexing.qualityOfService = .userInitiated
        previews.totalCostLimit = 64 * 1024 * 1024
    }

    func raster(at url: URL, full: Bool) throws -> Raster {
        let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(url.path)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(attributes.fileSize ?? 0)" as NSString
        if !full, let cached = previews.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { throw ViewerError.unreadable }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let size = CGSize(width: rotated ? height.doubleValue : width.doubleValue,
                          height: rotated ? width.doubleValue : height.doubleValue)
        let edge = full ? Int(max(size.width, size.height)) : 1600
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ViewerError.unreadable
        }
        // ponytail: full-detail images decode whole; use disk-backed tiles if plots exceed 50 MP.
        let raster = Raster(image: image, size: size,
                            fullDetail: full || (image.width >= Int(size.width) && image.height >= Int(size.height)))
        if !full { previews.setObject(raster, forKey: key, cost: raster.cost) }
        return raster
    }
}

enum ViewCommand { case fit, actualSize }

final class Pane: ObservableObject, Identifiable {
    let id = UUID()
    @Published var folder: URL?
    @Published var files: [URL] = []
    var fileFilter: FileFilter = .all
    private var allFiles: [URL] = []
    @Published var index = 0
    @Published var indexing = false
    @Published var loading = false
    @Published var loadingDetail = false
    @Published var error: String?
    @Published var detailError: String?
    @Published var raster: Raster?
    @Published var nativeImage: NSImage?
    @Published var pdf: PDFDocument?
    @Published var pdfPage = 0
    @Published var command: ViewCommand = .fit
    @Published var commandNumber = 0
    var current: URL? { files.indices.contains(index) ? files[index] : nil }
    var selectedURL: URL? { current ?? pendingSelection }
    private var pendingSelection: URL?
    private var scanNumber = 0
    private var loadNumber = 0
    private var scan: Operation?
    private var loads: [Operation] = []
    private var detailRequested = false

    func view(_ command: ViewCommand) {
        self.command = command
        commandNumber += 1
    }

    func open(_ folder: URL, refresh: Bool = false, selecting selected: URL? = nil, restoring: Bool = false) {
        let previous = selected ?? (refresh ? current : nil)
        pendingSelection = previous
        let previousIndex = refresh ? index : 0
        cancelLoads()
        scan?.cancel()
        scanNumber += 1
        let number = scanNumber
        self.folder = folder
        allFiles = []
        files = []
        index = 0
        error = nil
        indexing = true
        let job = BlockOperation()
        job.addExecutionBlock { [weak self, weak job] in
            guard let job, !job.isCancelled else { return }
            let result = Result { try Catalog.files(in: folder, cancelled: { job.isCancelled }) }
            guard !job.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanNumber == number else { return }
                self.indexing = false
                switch result {
                case .success(let files):
                    self.allFiles = files
                    self.showFiles(preserving: previous, oldIndex: previousIndex)
                case .failure(let error):
                    self.pendingSelection = nil
                    if restoring { self.folder = nil }
                    else { self.error = error.localizedDescription }
                }
            }
        }
        scan = job
        Loader.shared.indexing.addOperation(job)
    }

    func refresh() {
        guard let folder else { return }
        Loader.shared.previews.removeAllObjects()
        open(folder, refresh: true)
    }

    func setFilter(_ filter: FileFilter) {
        guard fileFilter != filter else { return }
        let previous = current
        let previousIndex = index
        fileFilter = filter
        if allFiles.isEmpty && error != nil { return }
        showFiles(preserving: previous, oldIndex: previousIndex)
    }

    private func showFiles(preserving previous: URL?, oldIndex: Int) {
        let visible = allFiles.filter(fileFilter.includes)
        let match = previous.flatMap { old -> URL? in
            if visible.contains(old) { return old }
            return visible.first { $0.deletingPathExtension().lastPathComponent == old.deletingPathExtension().lastPathComponent }
        }
        files = visible
        index = Catalog.selection(in: visible, preserving: match, oldIndex: oldIndex)
        pendingSelection = nil
        load()
    }

    func select(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        if folder?.path == parent.path, let position = files.firstIndex(of: url) {
            guard index != position else { return }
            index = position
            load()
        } else {
            open(parent, selecting: url)
        }
    }

    func cancelLoads() {
        loads.forEach { $0.cancel() }
        loads.removeAll()
        loadNumber += 1
        raster = nil
        nativeImage = nil
        pdf = nil
        pdfPage = 0
        loading = false
        loadingDetail = false
        detailRequested = false
        detailError = nil
    }

    func close() {
        scan?.cancel()
        scanNumber += 1
        cancelLoads()
    }

    deinit {
        scan?.cancel()
        loads.forEach { $0.cancel() }
    }

    func load() {
        cancelLoads()
        error = nil
        view(.fit)
        guard let url = current else { return }
        loading = true
        let number = loadNumber
        let job = BlockOperation()
        job.queuePriority = .veryHigh
        job.addExecutionBlock { [weak self, weak job] in
            guard let job, !job.isCancelled else { return }
            autoreleasepool {
                let result: Result<(Raster?, PDFDocument?, NSImage?), Error> = Result {
                    if url.pathExtension.lowercased() == "pdf" {
                        guard let document = PDFDocument(url: url) else { throw ViewerError.unreadable }
                        guard !document.isLocked else { throw ViewerError.lockedPDF }
                        guard document.pageCount > 0 else { throw ViewerError.unreadable }
                        return (nil, document, nil)
                    }
                    if ["svg", "gif"].contains(url.pathExtension.lowercased()) {
                        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0
                        else { throw ViewerError.unreadable }
                        return (nil, nil, image)
                    }
                    return (try Loader.shared.raster(at: url, full: false), nil, nil)
                }
                guard !job.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loadNumber == number else { return }
                    self.loading = false
                    switch result {
                    case .success(let content):
                        self.raster = content.0
                        self.pdf = content.1
                        self.nativeImage = content.2
                    case .failure(let error): self.error = error.localizedDescription
                    }
                    self.prefetch()
                }
            }
        }
        loads.append(job)
        Loader.shared.decoding.addOperation(job)
    }

    func requestFullDetail() {
        guard let url = current, let raster, !raster.fullDetail, !detailRequested else { return }
        detailRequested = true
        loadingDetail = true
        let number = loadNumber
        let job = BlockOperation()
        job.queuePriority = .veryHigh
        job.addExecutionBlock { [weak self, weak job] in
            guard let job, !job.isCancelled else { return }
            autoreleasepool {
                let result = Result { try Loader.shared.raster(at: url, full: true) }
                guard !job.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loadNumber == number else { return }
                    self.loadingDetail = false
                    switch result {
                    case .success(let raster): self.raster = raster
                    case .failure(let error): self.detailError = "Full detail unavailable: \(error.localizedDescription)"
                    }
                }
            }
        }
        loads.append(job)
        Loader.shared.decoding.addOperation(job)
    }

    private func prefetch() {
        for next in [index - 1, index + 1] where files.indices.contains(next) {
            let url = files[next]
            guard !["pdf", "svg", "gif"].contains(url.pathExtension.lowercased()) else { continue }
            let job = BlockOperation()
            job.queuePriority = .veryLow
            job.addExecutionBlock { [weak job] in
                guard job?.isCancelled == false else { return }
                autoreleasepool { _ = try? Loader.shared.raster(at: url, full: false) }
            }
            loads.append(job)
            Loader.shared.decoding.addOperation(job)
        }
    }
}

final class WindowModel: ObservableObject {
    @Published var panes = [Pane()]
    @Published var activeID = UUID()
    @Published var linked = false
    @Published var stacked = false
    @Published var fileFilter: FileFilter = .all {
        didSet { panes.forEach { $0.setFilter(fileFilter) } }
    }
    private var subscriptions: [AnyCancellable] = []
    var active: Pane { panes.first(where: { $0.id == activeID }) ?? panes[0] }

    init() {
        activeID = panes[0].id
        observePanes()
    }

    private func observePanes() {
        subscriptions = panes.map { pane in
            pane.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    func close() { panes.forEach { $0.close() } }

    func addPane() {
        guard panes.count < 4 else { return }
        let pane = Pane()
        pane.fileFilter = fileFilter
        panes.append(pane)
        activeID = pane.id
        observePanes()
    }

    func removePane() {
        guard panes.count > 1, let selected = panes.firstIndex(where: { $0.id == activeID }) else { return }
        let index = panes[selected].folder == nil ? selected
            : panes.lastIndex(where: { $0.folder == nil }) ?? selected
        panes[index].close()
        panes.remove(at: index)
        if index == selected { activeID = panes[min(index, panes.count - 1)].id }
        observePanes()
    }

    func cyclePane(backward: Bool = false) {
        let index = panes.firstIndex(where: { $0.id == activeID }) ?? 0
        activeID = panes[(index + (backward ? panes.count - 1 : 1)) % panes.count].id
    }

    func targets(from pane: Pane) -> [Pane] {
        linked ? panes.filter { !$0.files.isEmpty } : [pane]
    }

    func canMove(_ step: Int, from pane: Pane) -> Bool {
        // Do not let partially indexed folders silently lose linked alignment.
        if linked && panes.contains(where: { $0.indexing }) { return false }
        return Catalog.canMove(targets(from: pane).map { ($0.index, $0.files.count) }, by: step)
    }

    func move(_ step: Int, from pane: Pane) {
        activeID = pane.id
        guard canMove(step, from: pane) else { return }
        for target in targets(from: pane) where target.files.count > 1 {
            let count = target.files.count
            target.index = (target.index + step % count + count) % count
            target.load()
        }
    }

    func acceptDrop(_ providers: [NSItemProvider], into pane: Pane) -> Bool {
        guard let provider = providers.first, provider.canLoadObject(ofClass: URL.self) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { [weak self, weak pane] url, _ in
            guard let url, url.isFileURL,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
            DispatchQueue.main.async {
                guard let self, let pane, self.panes.contains(where: { $0 === pane }) else { return }
                self.activeID = pane.id
                pane.open(url)
            }
        }
        return true
    }

    func chooseFolder(for pane: Pane? = nil) {
        let pane = pane ?? active
        activeID = pane.id
        let panel = NSOpenPanel()
        panel.title = "Open a folder of plots"
        panel.prompt = "Open Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = pane.folder ?? panes.compactMap(\.folder).last?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { [weak self, weak pane] response in
            guard response == .OK, let url = panel.url, let self, let pane,
                  self.panes.contains(where: { $0 === pane }) else { return }
            pane.open(url)
        }
    }

    func chooseImage(for pane: Pane) {
        activeID = pane.id
        let panel = NSOpenPanel()
        panel.title = "Choose an image"
        panel.prompt = "Open Image"
        panel.allowedContentTypes = fileFilter.allowedTypes
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = pane.folder ?? FileManager.default.homeDirectoryForCurrentUser
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { [weak self, weak pane] response in
            guard response == .OK, let url = panel.url, let self, let pane,
                  self.panes.contains(where: { $0 === pane }) else { return }
            pane.select(url)
        }
    }
}

struct ViewerTab: Identifiable {
    let id = UUID()
    let number: Int
    var name: String?
    let model = WindowModel()

    var title: String { name ?? "Tab \(number)" }
}

private struct SavedSession: Codable {
    struct SavedPane: Codable {
        var folder: String?
        var file: String?
    }
    struct SavedTab: Codable {
        var number: Int
        var name: String?
        var panes: [SavedPane]
        var activePane: Int
        var filter: FileFilter
        var linked: Bool
        var stacked: Bool?
    }
    var tabs: [SavedTab]
    var activeTab: Int

    var isValid: Bool {
        (1...8).contains(tabs.count) && tabs.indices.contains(activeTab)
            && Set(tabs.map(\.number)).count == tabs.count
            && tabs.allSatisfy {
                (1...8).contains($0.number) && (1...4).contains($0.panes.count)
                    && $0.panes.indices.contains($0.activePane)
                    && $0.panes.allSatisfy { pane in
                        [pane.folder, pane.file].compactMap { $0 }.allSatisfy { $0.hasPrefix("/") }
                    }
            }
    }
}

final class TabsModel: ObservableObject {
    static let sessionKey = "viewerSession"
    private let defaults: UserDefaults?
    @Published private(set) var tabs: [ViewerTab]
    @Published var activeID: UUID {
        didSet {
            guard activeID != oldValue else { return }
            tabs.first(where: { $0.id == oldValue })?.model.panes.forEach { $0.cancelLoads() }
            tabs.first(where: { $0.id == activeID })?.model.panes.forEach {
                if $0.current != nil { $0.load() }
            }
        }
    }
    private var subscriptions: [AnyCancellable] = []
    var active: ViewerTab { tabs.first(where: { $0.id == activeID }) ?? tabs[0] }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        let first = ViewerTab(number: 1)
        tabs = [first]
        activeID = first.id
        if let data = defaults?.data(forKey: Self.sessionKey),
           let saved = try? JSONDecoder().decode(SavedSession.self, from: data), saved.isValid {
            tabs = saved.tabs.map { savedTab in
                var tab = ViewerTab(number: savedTab.number)
                tab.name = savedTab.name
                let model = tab.model
                for _ in savedTab.panes.dropFirst() { model.addPane() }
                model.fileFilter = savedTab.filter
                model.linked = savedTab.linked
                model.stacked = savedTab.stacked ?? false
                model.activeID = model.panes[savedTab.activePane].id
                for (pane, savedPane) in zip(model.panes, savedTab.panes) {
                    guard let path = savedPane.folder else { continue }
                    pane.open(URL(fileURLWithPath: path),
                              selecting: savedPane.file.map { URL(fileURLWithPath: $0) }, restoring: true)
                }
                return tab
            }
            activeID = tabs[saved.activeTab].id
        }
        observeTabs()
    }

    private func observeTabs() {
        subscriptions = tabs.map { tab in
            tab.model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    func addTab() {
        guard tabs.count < 8 else { return }
        let number = (1...8).first { candidate in !tabs.contains { $0.number == candidate } }!
        let tab = ViewerTab(number: number)
        tabs.append(tab)
        activeID = tab.id
        observeTabs()
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].model.close()
        tabs.remove(at: index)
        if activeID == id { activeID = tabs[min(index, tabs.count - 1)].id }
        observeTabs()
    }

    @discardableResult
    func moveTab(_ sourceID: UUID, to targetID: UUID) -> Bool {
        guard let source = tabs.firstIndex(where: { $0.id == sourceID }),
              let target = tabs.firstIndex(where: { $0.id == targetID }), source != target else { return false }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: target)
        return true
    }

    func renameTab(_ id: UUID, to name: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].name = trimmed.isEmpty ? nil : trimmed
    }

    func saveSession() {
        guard let defaults else { return }
        let saved = SavedSession(tabs: tabs.map { tab in
            let model = tab.model
            return SavedSession.SavedTab(number: tab.number, name: tab.name,
                panes: model.panes.map { SavedSession.SavedPane(folder: $0.folder?.path, file: $0.selectedURL?.path) },
                activePane: model.panes.firstIndex { $0.id == model.activeID } ?? 0,
                filter: model.fileFilter, linked: model.linked, stacked: model.stacked)
        }, activeTab: tabs.firstIndex { $0.id == activeID } ?? 0)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.sessionKey) }
    }

    func clearAll() {
        tabs.forEach { $0.model.close() }
        let first = ViewerTab(number: 1)
        tabs = [first]
        activeID = first.id
        observeTabs()
        defaults?.removeObject(forKey: Self.sessionKey)
        Loader.shared.previews.removeAllObjects()
    }

    func close() {
        saveSession()
        tabs.forEach { $0.model.close() }
    }
}

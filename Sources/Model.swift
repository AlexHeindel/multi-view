import AppKit
import Combine
import ImageIO
import PDFKit

enum Catalog {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "pdf"]

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
        !positions.isEmpty && positions.allSatisfy { $0.index + step >= 0 && $0.index + step < $0.count }
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
        decoding.name = "Plot Viewer decoding"
        decoding.maxConcurrentOperationCount = 2
        decoding.qualityOfService = .userInitiated
        indexing.name = "Plot Viewer folder indexing"
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
    @Published var index = 0
    @Published var indexing = false
    @Published var loading = false
    @Published var loadingDetail = false
    @Published var error: String?
    @Published var detailError: String?
    @Published var raster: Raster?
    @Published var pdf: PDFDocument?
    @Published var pdfPage = 0
    @Published var command: ViewCommand = .fit
    @Published var commandNumber = 0
    var current: URL? { files.indices.contains(index) ? files[index] : nil }
    private var scanNumber = 0
    private var loadNumber = 0
    private var scan: Operation?
    private var loads: [Operation] = []
    private var detailRequested = false

    func view(_ command: ViewCommand) {
        self.command = command
        commandNumber += 1
    }

    func open(_ folder: URL, refresh: Bool = false) {
        let previous = refresh ? current : nil
        let previousIndex = refresh ? index : 0
        cancelLoads()
        scan?.cancel()
        scanNumber += 1
        let number = scanNumber
        self.folder = folder
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
                    self.files = files
                    self.index = Catalog.selection(in: files, preserving: previous, oldIndex: previousIndex)
                    self.load()
                case .failure(let error): self.error = error.localizedDescription
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

    func cancelLoads() {
        loads.forEach { $0.cancel() }
        loads.removeAll()
        loadNumber += 1
        raster = nil
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
                let result: Result<(Raster?, PDFDocument?), Error> = Result {
                    if url.pathExtension.lowercased() == "pdf" {
                        guard let document = PDFDocument(url: url) else { throw ViewerError.unreadable }
                        guard !document.isLocked else { throw ViewerError.lockedPDF }
                        guard document.pageCount > 0 else { throw ViewerError.unreadable }
                        return (nil, document)
                    }
                    return (try Loader.shared.raster(at: url, full: false), nil)
                }
                guard !job.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loadNumber == number else { return }
                    self.loading = false
                    switch result {
                    case .success(let content):
                        self.raster = content.0
                        self.pdf = content.1
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
            guard url.pathExtension.lowercased() != "pdf" else { continue }
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

    func addPane() {
        guard panes.count < 4 else { return }
        let pane = Pane()
        panes.append(pane)
        activeID = pane.id
        observePanes()
    }

    func removePane() {
        guard panes.count > 1, let index = panes.firstIndex(where: { $0.id == activeID }) else { return }
        panes[index].close()
        panes.remove(at: index)
        activeID = panes[min(index, panes.count - 1)].id
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
        for target in targets(from: pane) {
            target.index += step
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
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { pane.open(url) }
        }
    }
}

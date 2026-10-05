import AppKit
import ImageIO
import PDFKit
import CoreText

@main
enum Checks {
    static let fm = FileManager.default

    static func wait(_ message: String, timeout: TimeInterval = 30, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(condition(), "Timed out: \(message)")
    }

    static func label(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat) {
        context.textMatrix = .identity
        context.textPosition = point
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor
        ])
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }

    static func chart(in context: CGContext, width: Int, height: Int, series: Int) {
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let unit = CGFloat(width) / 1200
        context.saveGState()
        context.scaleBy(x: unit, y: CGFloat(height) / 800)
        label("Run \(series + 1)  /  Signal comparison", in: context, at: CGPoint(x: 90, y: 725), size: 26)
        label("Time (s)", in: context, at: CGPoint(x: 540, y: 28), size: 17)
        label("Amplitude", in: context, at: CGPoint(x: 90, y: 680), size: 16)
        for tick in 0...10 {
            let x = CGFloat(100 + tick * 100)
            context.setStrokeColor(CGColor(gray: 0.87, alpha: 1))
            context.setLineWidth(1)
            context.move(to: CGPoint(x: x, y: 85)); context.addLine(to: CGPoint(x: x, y: 660)); context.strokePath()
            label("\(tick)", in: context, at: CGPoint(x: x - 5, y: 58), size: 15)
        }
        context.setStrokeColor(CGColor(red: 0.10, green: 0.37 + CGFloat(series) * 0.09, blue: 0.76, alpha: 1))
        context.setLineWidth(2.5)
        for step in 0...2000 {
            let x = 100 + CGFloat(step) / 2
            let t = Double(step) / 200
            let y = 370 + 180 * sin(t * 2 + Double(series) * 0.35) * exp(-t / 13)
            if step == 0 { context.move(to: CGPoint(x: x, y: y)) }
            else { context.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.strokePath()
        label("Full-resolution detail: 0123456789", in: context, at: CGPoint(x: 750, y: 695), size: 8)
        context.restoreGState()
        // Alternating one-pixel stripes expose accidental preview-only rendering at 1:1.
        for x in 0..<200 {
            context.setFillColor(CGColor(gray: x.isMultiple(of: 2) ? 0 : 1, alpha: 1))
            context.fill(CGRect(x: width / 2 + x, y: height / 2, width: 1, height: 100))
        }
    }

    static func image(at url: URL, width: Int, height: Int, type: String = "public.png", series: Int = 0) throws {
        try autoreleasepool {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            chart(in: context, width: width, height: height, series: series)
            let image = context.makeImage()!
            let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ViewerError.unreadable }
        }
    }

    static func pdf(at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for series in 0..<3 {
            context.beginPDFPage(nil)
            chart(in: context, width: 1200, height: 800, series: series)
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func gif(at url: URL) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 2, nil)!
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for gray: CGFloat in [0, 1] {
            let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            CGImageDestinationAddImage(destination, context.makeImage()!, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ViewerError.unreadable }
    }

    static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/fixtures")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let unique = root.appendingPathComponent("check-" + UUID().uuidString)
        try fm.createDirectory(at: unique, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: unique) }
        let small = root.appendingPathComponent("sample.png")
        let jpeg = root.appendingPathComponent("sample.jpg")
        let large = root.appendingPathComponent("detail.tiff")
        let animation = root.appendingPathComponent("sample.gif")
        let vector = root.appendingPathComponent("sample.svg")
        let report = root.appendingPathComponent("report.pdf")
        try image(at: small, width: 1200, height: 800)
        try image(at: jpeg, width: 1200, height: 800, type: "public.jpeg")
        try image(at: large, width: 2400, height: 1600, type: "public.tiff")
        try gif(at: animation)
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='80' height='60'><rect width='80' height='60' fill='red'/></svg>".utf8).write(to: vector)
        pdf(at: report)
        precondition(CGImageSourceGetCount(CGImageSourceCreateWithURL(animation as CFURL, nil)!) == 2)
        let svgImage = NSImage(contentsOf: vector)!
        precondition(svgImage.size == CGSize(width: 80, height: 60))
        let nativeScroll = ImageScrollView()
        nativeScroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        nativeScroll.display(svgImage, animated: false)
        precondition(nativeScroll.canvas.vectorImage != nil)
        nativeScroll.display(NSImage(contentsOf: animation)!, animated: true)
        precondition(nativeScroll.canvas.animation.animates && !nativeScroll.canvas.animation.isHidden)
        for name in ["plot10.PNG", "plot2.png", "plot1.jpg", ".hidden.png", "notes.txt", "broken.tif"] {
            try Data("not an image".utf8).write(to: unique.appendingPathComponent(name))
        }
        try fm.createDirectory(at: unique.appendingPathComponent("nested.png"), withIntermediateDirectories: true)
        let files = try Catalog.files(in: unique)
        precondition(files.map(\.lastPathComponent) == ["broken.tif", "plot1.jpg", "plot2.png", "plot10.PNG"])
        precondition(files.filter(FileFilter.png.includes).map(\.lastPathComponent) == ["plot2.png", "plot10.PNG"])
        precondition(Catalog.selection(in: files, preserving: files[2], oldIndex: 0) == 2)
        precondition(Catalog.selection(in: Array(files.prefix(2)), preserving: files[3], oldIndex: 3) == 1)
        precondition(Catalog.selection(in: [], preserving: nil, oldIndex: 10) == 0)
        precondition(!Catalog.canMove([], by: 1))
        precondition(!Catalog.canMove([(0, 0)], by: 1))
        precondition(!Catalog.canMove([(0, 3)], by: -1))
        precondition(Catalog.canMove([(0, 3), (1, 3)], by: 1))
        precondition(!Catalog.canMove([(1, 3), (1, 2)], by: 1))
        precondition(!Catalog.canMove([(0, 3), (1, 2)], by: -1))
        let preview = try Loader.shared.raster(at: large, full: false)
        precondition(preview.image.width == 1600 && !preview.fullDetail)
        let full = try Loader.shared.raster(at: large, full: true)
        precondition(full.image.width == 2400 && full.image.height == 1600 && full.fullDetail)
        let scroll = ImageScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        var detailRequests = 0
        scroll.requestDetail = { detailRequests += 1 }
        scroll.display(Raster(image: preview.image, size: CGSize(width: 1640, height: 1093), fullDetail: false))
        scroll.actualSize()
        wait("original detail even just beyond preview resolution") { detailRequests > 0 }
        precondition(abs(scroll.magnification - 0.5) < 0.001)
        scroll.fit()
        precondition(scroll.fitting && scroll.magnification < 0.5)
        let fittedScale = scroll.magnification
        let wheelUp = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                              wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!)!
        let wheelDown = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                                wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0)!)!
        let preciseUp = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                                wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0)!)!
        let preciseDown = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                                  wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0)!)!
        let fastWheelUp = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                                  wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)!)!
        let fastWheelDown = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                                    wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0)!)!
        precondition(!wheelUp.hasPreciseScrollingDeltas)
        precondition(preciseUp.hasPreciseScrollingDeltas)
        for (up, down) in [(wheelUp, wheelDown), (preciseUp, preciseDown), (fastWheelUp, fastWheelDown)] {
            scroll.scrollWheel(with: up)
            precondition(!scroll.fitting && abs(scroll.magnification / fittedScale - 1.08) < 0.001)
            scroll.scrollWheel(with: down)
            precondition(abs(scroll.magnification - fittedScale) < 0.001)
        }
        let zoomWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        zoomWindow.contentView = scroll
        zoomWindow.makeKeyAndOrderFront(nil)
        let windowScale = scroll.magnification
        func imageWindowScroll(_ delta: Int32) {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                             wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
            cg.location = zoomWindow.convertPoint(toScreen: NSPoint(x: 300, y: 200))
            zoomWindow.sendEvent(NSEvent(cgEvent: cg)!)
        }
        imageWindowScroll(10)
        precondition(abs(scroll.magnification / windowScale - 1.08) < 0.001,
                     "Precise scroll must zoom one step through the window")
        imageWindowScroll(-10)
        precondition(abs(scroll.magnification - windowScale) < 0.001)
        zoomWindow.orderOut(nil)
        scroll.fit()
        precondition(scroll.fitting && abs(scroll.magnification - fittedScale) < 0.001)
        scroll.actualSize()
        precondition(abs(scroll.magnification - 1 / zoomWindow.backingScaleFactor) < 0.001)
        let pdfZoom = PlotPDFView()
        pdfZoom.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pdfZoom.document = PDFDocument(url: report)
        pdfZoom.autoScales = true
        let pdfScale = pdfZoom.scaleFactor
        for (up, down) in [(wheelUp, wheelDown), (preciseUp, preciseDown), (fastWheelUp, fastWheelDown)] {
            pdfZoom.scrollWheel(with: up)
            precondition(!pdfZoom.autoScales && abs(pdfZoom.scaleFactor / pdfScale - 1.08) < 0.001)
            pdfZoom.scrollWheel(with: down)
            precondition(abs(pdfZoom.scaleFactor - pdfScale) < 0.001)
        }
        pdfZoom.autoScales = true
        precondition(pdfZoom.autoScales)
        precondition(PDFDocument(url: report)?.pageCount == 3)

        let pane = Pane()
        pane.open(unique)
        wait("folder enumeration") { !pane.indexing && !pane.loading }
        precondition(pane.files == files && pane.error != nil)
        pane.select(files[2])
        wait("image selection") { !pane.loading }
        precondition(pane.index == 2 && pane.current == files[2], "index=\(pane.index) current=\(pane.current?.path ?? "nil") target=\(files[2].path)")
        pane.select(small)
        wait("image selection from another folder") { !pane.indexing && !pane.loading }
        precondition(pane.current == small && pane.folder == root)
        pane.open(unique)
        wait("reopen folder") { !pane.indexing && !pane.loading }
        pane.index = 2
        pane.refresh()
        wait("refresh") { !pane.indexing && !pane.loading }
        precondition(pane.current?.lastPathComponent == "plot2.png")
        try fm.removeItem(at: unique.appendingPathComponent("plot2.png"))
        pane.refresh()
        wait("refresh after removal") { !pane.indexing && !pane.loading }
        precondition(pane.current?.lastPathComponent == "plot10.PNG")
        pane.open(unique.appendingPathComponent("gone"))
        wait("removed folder") { !pane.indexing }
        precondition(pane.error != nil && pane.files.isEmpty)
        let empty = unique.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        pane.open(unique)
        pane.open(empty)
        wait("stale folder result") { !pane.indexing }
        precondition(pane.folder == empty && pane.files.isEmpty && pane.error == nil)
        pane.files = [large, unique.appendingPathComponent("broken.tif")]
        pane.index = 0
        pane.load()
        pane.index = 1
        pane.load()
        wait("stale image result") { !pane.loading }
        precondition(pane.raster == nil && pane.error != nil)
        pane.index = 0
        pane.load()
        wait("preview") { pane.raster != nil }
        pane.requestFullDetail()
        pane.index = 1
        pane.load()
        wait("stale full-detail result") { !pane.loading }
        precondition(pane.raster == nil && pane.error != nil && !pane.loadingDetail)
        pane.files = [report]
        pane.index = 0
        pane.load()
        wait("PDF") { !pane.loading }
        precondition(pane.pdf?.pageCount == 3)
        pane.close()

        let model = WindowModel()
        model.addPane()
        let left = model.panes[0], right = model.panes[1]
        left.files = [small, large, report]; right.files = [small, report]
        model.linked = true
        model.move(1, from: left)
        precondition(left.index == 1 && right.index == 1)
        model.move(1, from: left)
        precondition(left.index == 1 && right.index == 1)
        model.linked = false
        model.move(1, from: left)
        precondition(left.index == 2 && right.index == 1)
        model.linked = true
        model.move(-1, from: left)
        precondition(left.index == 1 && right.index == 0)
        model.addPane(); model.addPane(); model.addPane()
        precondition(model.panes.count == 4)
        model.cyclePane()
        precondition(model.activeID == left.id)
        model.cyclePane(backward: true)
        precondition(model.activeID == model.panes[3].id)
        model.removePane(); model.removePane(); model.removePane(); model.removePane()
        precondition(model.panes.count == 1)
        precondition(!model.acceptDrop([], into: model.active))
        precondition(!model.acceptDrop([NSItemProvider(object: "not a folder" as NSString)], into: model.active))
        precondition(model.acceptDrop([NSItemProvider(object: empty as NSURL)], into: model.active))
        wait("folder drop") { model.active.folder == empty && !model.active.indexing }
        precondition(model.active.files.isEmpty && model.active.error == nil)
        model.panes.forEach { $0.close() }
        let removal = WindowModel()
        removal.active.folder = unique
        removal.addPane()
        let blankID = removal.activeID
        removal.addPane()
        removal.active.folder = empty
        let selectedID = removal.activeID
        removal.removePane()
        precondition(removal.panes.count == 2 && !removal.panes.contains { $0.id == blankID })
        precondition(removal.activeID == selectedID && removal.panes.allSatisfy { $0.folder != nil })
        removal.removePane()
        precondition(removal.panes.count == 1 && removal.panes[0].folder == unique)
        removal.close()
        let tabs = TabsModel()
        let firstTab = tabs.active.id
        tabs.active.model.addPane()
        tabs.active.model.linked = true
        let retainedPane = tabs.active.model.active
        retainedPane.files = [small]
        retainedPane.raster = preview
        tabs.addTab()
        precondition(retainedPane.raster == nil)
        let secondTab = tabs.active.id
        tabs.activeID = firstTab
        wait("tab image reload") { !retainedPane.loading && retainedPane.raster != nil }
        tabs.addTab()
        precondition(tabs.tabs.last?.id == tabs.activeID && tabs.tabs[1].id == secondTab)
        let thirdTab = tabs.active.id
        tabs.renameTab(secondTab, to: "  Comparison  ")
        precondition(tabs.tabs[1].title == "Comparison")
        precondition(tabs.moveTab(thirdTab, to: firstTab))
        precondition(tabs.tabs.map(\.number) == [3, 1, 2] && tabs.activeID == thirdTab)
        precondition(tabs.tabs[2].title == "Comparison")
        precondition(tabs.moveTab(firstTab, to: secondTab))
        precondition(tabs.tabs.map(\.number) == [3, 2, 1])
        precondition(tabs.moveTab(firstTab, to: secondTab))
        precondition(tabs.tabs.map(\.number) == [3, 1, 2])
        tabs.renameTab(secondTab, to: " ")
        precondition(tabs.tabs[2].title == "Tab 2")
        for _ in 0..<8 { tabs.addTab() }
        precondition(tabs.tabs.count == 8 && tabs.active.model.panes.count == 1)
        precondition(!tabs.active.model.linked && tabs.tabs.first(where: { $0.id == firstTab })?.model.panes.count == 2)
        tabs.closeTab(firstTab)
        precondition(tabs.tabs.count == 7 && tabs.active.model.panes.count == 1)
        precondition(tabs.tabs.first(where: { $0.id == thirdTab })?.number == 3)
        tabs.addTab()
        precondition(tabs.tabs.count == 8 && Set(tabs.tabs.map(\.number)).count == 8)
        precondition(tabs.active.number == 1 && tabs.tabs.first(where: { $0.id == secondTab })?.number == 2)
        tabs.closeTab(tabs.activeID)
        precondition(tabs.tabs.count == 7 && tabs.tabs.contains { $0.id == tabs.activeID })
        tabs.close()
        let paired = unique.appendingPathComponent("paired")
        try fm.createDirectory(at: paired, withIntermediateDirectories: true)
        try fm.copyItem(at: small, to: paired.appendingPathComponent("same.png"))
        try fm.copyItem(at: jpeg, to: paired.appendingPathComponent("same.jpg"))
        try fm.copyItem(at: large, to: paired.appendingPathComponent("same.tiff"))
        try fm.copyItem(at: animation, to: paired.appendingPathComponent("same.gif"))
        try fm.copyItem(at: vector, to: paired.appendingPathComponent("same.svg"))
        try fm.copyItem(at: report, to: paired.appendingPathComponent("same.pdf"))
        let filtered = WindowModel()
        filtered.active.open(paired)
        wait("paired folder") { !filtered.active.indexing && !filtered.active.loading }
        filtered.fileFilter = .png
        wait("PNG filter") { !filtered.active.loading }
        precondition(filtered.active.files.map(\.lastPathComponent) == ["same.png"])
        filtered.fileFilter = .jpeg
        wait("JPEG filter") { !filtered.active.loading }
        precondition(filtered.active.current?.lastPathComponent == "same.jpg" && filtered.active.raster != nil)
        precondition(FileFilter.jpeg.includes(URL(fileURLWithPath: "same.JPEG")))
        filtered.fileFilter = .tiff
        wait("TIFF filter") { !filtered.active.loading }
        precondition(filtered.active.current?.lastPathComponent == "same.tiff" && filtered.active.raster != nil)
        precondition(FileFilter.tiff.includes(URL(fileURLWithPath: "same.TIF")))
        filtered.fileFilter = .gif
        wait("GIF filter") { !filtered.active.loading }
        precondition(filtered.active.current?.lastPathComponent == "same.gif" && filtered.active.nativeImage != nil)
        filtered.fileFilter = .svg
        wait("SVG filter") { !filtered.active.loading }
        precondition(filtered.active.current?.lastPathComponent == "same.svg" && filtered.active.nativeImage != nil)
        filtered.fileFilter = .pdf
        wait("PDF filter") { !filtered.active.loading }
        precondition(filtered.active.current?.lastPathComponent == "same.pdf")
        filtered.addPane()
        filtered.active.open(paired)
        wait("new pane inherits filter") { !filtered.active.indexing && !filtered.active.loading }
        precondition(filtered.active.files.map(\.lastPathComponent) == ["same.pdf"])
        filtered.fileFilter = .all
        wait("all files filter") { filtered.panes.allSatisfy { !$0.loading } }
        precondition(filtered.panes.allSatisfy { $0.files.count == 6 })
        filtered.panes.forEach { $0.close() }
        try checkSession(folder: paired, image: jpeg)
        print("PASS: session restore/reset, pane removal, tab reorder/rename/numbering, image formats, navigation, refresh, drops, stale results, zoom, and multipage PDF.")
        if CommandLine.arguments.contains("stress") { try stress(root: root) }
    }

    static func checkSession(folder: URL, image: URL) throws {
        let suite = "local.multiview.checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let moved = folder.appendingPathComponent("moved")
        let deleted = folder.appendingPathComponent("deleted")
        try fm.createDirectory(at: moved, withIntermediateDirectories: true)
        try fm.createDirectory(at: deleted, withIntermediateDirectories: true)
        let selected = folder.appendingPathComponent("selected.jpg")
        try fm.copyItem(at: image, to: selected)
        defer {
            try? fm.removeItem(at: selected)
            try? fm.removeItem(at: folder.appendingPathComponent("renamed"))
        }

        let original = TabsModel(defaults: defaults)
        let first = original.active.id
        original.renameTab(first, to: "Comparison")
        let model = original.active.model
        model.fileFilter = .jpeg
        model.linked = true
        model.stacked = true
        model.active.open(folder, selecting: selected)
        model.addPane(); model.active.open(moved)
        model.addPane(); model.active.open(deleted)
        model.addPane()
        model.activeID = model.panes[0].id
        wait("session setup") { model.panes.allSatisfy { !$0.indexing && !$0.loading } }
        original.addTab()
        original.active.model.active.open(folder)
        wait("second session tab") { !original.active.model.active.indexing && !original.active.model.active.loading }
        original.moveTab(original.activeID, to: first)
        original.activeID = first
        original.close()
        let savedData = defaults.data(forKey: TabsModel.sessionKey)!
        var legacy = try JSONSerialization.jsonObject(with: savedData) as! [String: Any]
        legacy["tabs"] = (legacy["tabs"] as! [[String: Any]]).map { tab in
            var tab = tab
            tab.removeValue(forKey: "stacked")
            return tab
        }
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: TabsModel.sessionKey)
        let oldSession = TabsModel(defaults: defaults)
        precondition(oldSession.tabs.allSatisfy { !$0.model.stacked })
        oldSession.tabs.forEach { $0.model.close() }
        defaults.set(savedData, forKey: TabsModel.sessionKey)
        try fm.moveItem(at: moved, to: folder.appendingPathComponent("renamed"))
        try fm.removeItem(at: deleted)

        let restored = TabsModel(defaults: defaults)
        // Quitting while folders are still indexing must retain the selected file path.
        restored.saveSession()
        let reopened = TabsModel(defaults: defaults)
        wait("session restore") {
            reopened.tabs.allSatisfy { $0.model.panes.allSatisfy { !$0.indexing && !$0.loading } }
        }
        precondition(reopened.tabs.map(\.number) == [2, 1] && reopened.active.number == 1)
        precondition(reopened.active.title == "Comparison")
        let restoredModel = reopened.active.model
        precondition(restoredModel.panes.count == 4 && restoredModel.activeID == restoredModel.panes[0].id)
        precondition(restoredModel.linked && restoredModel.stacked && restoredModel.fileFilter == .jpeg)
        precondition(!reopened.tabs[0].model.stacked)
        precondition(restoredModel.active.folder?.path == folder.path && restoredModel.active.current?.path == selected.path,
                     "Restored folder=\(restoredModel.active.folder?.path ?? "nil"), file=\(restoredModel.active.current?.path ?? "nil")")
        precondition(restoredModel.panes.dropFirst().allSatisfy { $0.folder == nil && $0.error == nil && $0.files.isEmpty })
        precondition(reopened.tabs[0].model.active.folder?.path == folder.path)
        restored.tabs.forEach { $0.model.close() }
        reopened.close()

        // A missing image falls back to a supported file in the surviving folder.
        try fm.removeItem(at: selected)
        let missingImage = TabsModel(defaults: defaults)
        wait("missing saved image") { !missingImage.active.model.active.indexing && !missingImage.active.model.active.loading }
        precondition(missingImage.active.model.active.current?.lastPathComponent == "same.jpg")
        missingImage.clearAll()
        precondition(defaults.data(forKey: TabsModel.sessionKey) == nil)
        precondition(missingImage.tabs.count == 1 && missingImage.active.number == 1)
        precondition(missingImage.active.model.panes.count == 1 && missingImage.active.model.active.folder == nil)
        precondition(!missingImage.active.model.linked && !missingImage.active.model.stacked
                     && missingImage.active.model.fileFilter == .all)
        missingImage.close()
        let fresh = TabsModel(defaults: defaults)
        precondition(fresh.tabs.count == 1 && fresh.active.model.panes.count == 1 && fresh.active.model.active.folder == nil)
        fresh.close()
        defaults.set(Data("invalid session".utf8), forKey: TabsModel.sessionKey)
        let corrupt = TabsModel(defaults: defaults)
        precondition(corrupt.tabs.count == 1 && corrupt.active.model.active.folder == nil)
        corrupt.close()
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    static func stress(root: URL) throws {
        print("Preparing four folders of 10,000 files, each a 7000 × 7000 (49 MP) raster…")
        var folders: [URL] = []
        for series in 0..<4 {
            let folder = root.appendingPathComponent("Run-\(series + 1)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let original = folder.appendingPathComponent("plot1.png")
            if !fm.fileExists(atPath: original.path) { try image(at: original, width: 7000, height: 7000, series: series) }
            for index in 2...10000 {
                let target = folder.appendingPathComponent("plot\(index).png")
                if !fm.fileExists(atPath: target.path) { try fm.linkItem(at: original, to: target) }
            }
            folders.append(folder)
        }
        let model = WindowModel()
        for _ in 0..<3 { model.addPane() }
        let start = Date()
        for (pane, folder) in zip(model.panes, folders) { pane.open(folder) }
        wait("40,000-file indexing", timeout: 120) { model.panes.allSatisfy { !$0.indexing && !$0.loading } }
        precondition(model.panes.allSatisfy { $0.files.count == 10000 && $0.raster != nil })
        print(String(format: "Four indexed folders + previews: %.2f s", Date().timeIntervalSince(start)))
        model.linked = true
        var memory: [Double] = []
        for round in 0..<8 {
            autoreleasepool {
                if round > 0 { model.move(1, from: model.panes[0]) }
                wait("previews") { model.panes.allSatisfy { !$0.loading } }
                model.panes.forEach { $0.requestFullDetail() }
                wait("49 MP original detail", timeout: 120) { model.panes.allSatisfy { !$0.loadingDetail } }
                precondition(model.panes.allSatisfy { $0.raster?.image.width == 7000 && $0.raster?.fullDetail == true })
            }
            memory.append(residentMB())
            print(String(format: "Full-detail round %d: %.0f MB resident", round + 1, memory.last!))
        }
        precondition((memory.suffix(3).max() ?? 0) < (memory.dropFirst().prefix(3).max() ?? 0) + 512,
                     "Memory growth exceeded 512 MB after warmup")
        for _ in 0..<50 { model.move(1, from: model.panes[0]) }
        wait("rapid navigation", timeout: 120) { model.panes.allSatisfy { !$0.loading } }
        precondition(model.panes.allSatisfy { $0.index == 57 && $0.raster != nil })
        model.panes.forEach { $0.close() }
        Loader.shared.decoding.waitUntilAllOperationsAreFinished()
        Loader.shared.previews.removeAllObjects()
        print("PASS: 40,000 files, four simultaneous 49 MP originals, eight browsing rounds, and 50 rapid linked steps.")
        print("Reusable UI fixtures: \(root.path)")
    }
}

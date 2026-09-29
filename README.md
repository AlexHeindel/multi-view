# Multi-view

A small native Mac app for comparing folders of plots. SwiftUI, AppKit, ImageIO, and PDFKit; no external dependencies or network access. Requires macOS 14 or later. Built and tested on this Mac with macOS 26.6.2 and Swift 6.3.3.

## Open the app

Double-click **`build/Multi-view.app`** in Finder. For a permanent Dock shortcut, copy it to Applications, launch it there, then right-click its Dock icon and choose **Options → Keep in Dock**. The app is signed locally for personal use, not notarized for distribution.

Choose **Open Folder** and select a folder of PNG, JPEG, TIFF, GIF, SVG, or PDF plots. Add up to four panes and open a different folder in each, or drop a folder onto a pane. Only files directly inside the folder are listed, in Finder-style filename order (`plot2` before `plot10`). Hidden files and subfolders are ignored. GIFs animate, multipage TIFFs show their first image, and PDFs have separate page controls.

The app opens with one tab. Click **+** after the rightmost tab (or press **Command-N**) to add up to eight tabs, each with its own one to four panes. Scroll the tab strip horizontally to reach tabs that do not fit in the toolbar. Tabs keep their own folders, selected pane, file filter, and linked navigation setting. Use **×** to close a tab; one tab always stays open.

Click a pane to select it; its outline turns blue. Browse using the pane’s arrows or the keyboard. Click the filename in a pane’s header to choose a particular image with the macOS file picker; it opens in that pane’s current folder and can also open an image from another folder. **Link Navigation** makes file arrows move all populated panes together, preserving their current offsets. It stops at the first/last file of the shortest remaining sequence. Empty panes are ignored, and linked movement waits until folder indexing finishes. Matching filenames is not required.

Drag a divider to resize the panes. With four panes, each row’s vertical divider and the divider between rows can be dragged. Use **Equalize Panes** in the toolbar to restore even sizes.

Use the toolbar’s **File Type** menu to show PNG, JPEG, TIFF, GIF, SVG, PDF, or **All** supported files in every pane. Changing the filter keeps the current file when possible, or selects a same-named file in the chosen format. JPEG includes `.jpg` and `.jpeg`; TIFF includes `.tif` and `.tiff`.

| Action | Shortcut / gesture |
| --- | --- |
| Previous / next file | Left / Right |
| Next / previous pane | Tab / Shift-Tab |
| Open folder in selected pane | Command-O |
| New tab | Command-N |
| Add pane | Command-T |
| Remove selected pane | Command-Shift-W |
| Toggle linked navigation | Command-L |
| Refresh selected folder | Command-R |
| Fit plot to pane | Command-0 |
| Actual Size | Command-1 |
| Zoom | Trackpad pinch |
| Pan raster | Drag or scroll |
| Pan PDF | Scroll |

At **1:1**, one raster image pixel corresponds to one screen pixel, including on Retina screens. PDF **100%** uses PDFKit’s native scale. Zoom/pan are independent between panes and reset on file changes or tab switches. SVGs and PDFs remain vector rendered. The Compare menu also offers Reveal File in Finder.

Folder contents are never modified. Refresh rescans a folder, retaining the current file if it still exists. Sessions are not saved, and folder watching, annotations, and quantitative analysis are not included.

## Build and verify

From this folder, with Apple Command Line Tools installed:

```sh
./build.sh
open 'build/Multi-view.app'
./build.sh test
./build.sh stress
```

The build script targets macOS 14+ for the current Mac’s architecture. It builds an optimized executable, assembles the app bundle, and applies an ad-hoc signature. No full Xcode installation is needed.

The assertion-based check covers tab and pane limits, ordering/filtering for all supported formats, GIF and SVG loading, direct image selection, independent and linked navigation, refresh selection, folder-drop URL delivery, empty/missing/corrupt files, obsolete asynchronous results, original raster dimensions, and multipage PDFs. The stress option creates four folders with 10,000 hard-linked image entries each, then exercises four 49-megapixel originals, repeated full-detail browsing, and rapid linked navigation. Generated fixtures and compiler outputs are kept in `.build/` and are not source files.

The app also accepts up to four folder paths as launch arguments. For folders protected by macOS privacy controls, select them using **Open Folder** first if access is denied; a raw command-line path does not grant folder access.

Native UI checks on this Mac covered 1–4 panes, eight-tab toolbar layout, GIF/SVG filter choices and SVG rendering, folder selection, keyboard focus, linked file movement, original-pixel rendering at Actual Size, and PDF page controls/reset. Folder-drop delivery was checked with `NSItemProvider`; a physical Finder drag and trackpad pinch were not manually exercised.

## Large images

Folder enumeration and decoding run off the main thread. Decoding is limited to two concurrent jobs. Each raster starts with a preview up to 1600 pixels on its longest edge; zooming past the preview resolution requests the original. The loading badge stays visible until original detail is ready. Full-resolution images are retained only for displayed files, and the preview cache has a 64 MB cost limit (an eviction hint, not a total process-memory ceiling).

Full-detail decoding uses the entire source image. Four 49-megapixel images used roughly 1.1–1.8 GB of resident memory in the initial stress run on this Mac. Switching tabs releases decoded images from the hidden tab and reloads the selected tab. Large-image decoder scratch space and native rendering add overhead beyond the displayed pixels. Disk-backed tiling would be needed for substantially larger rasters or a strict memory ceiling.

## Source layout

- `Sources/Model.swift`: folder catalog, asynchronous loading/cache, pane state, navigation.
- `Sources/Renderers.swift`: native raster, GIF, and SVG scroll/zoom views and PDFKit wrapper.
- `Sources/App.swift`: window, pane controls, folder dropping, menus, keyboard handling.
- `Tests/Checks.swift`: runnable checks and synthetic plot fixtures.

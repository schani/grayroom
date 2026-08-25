import AppKit
import CoreGraphics
import GrayroomCanvas
import GrayroomCore
import GrayroomLibrary
import GrayroomUI
import Metal
import QuartzCore

/// `GRAYROOM_SELFTEST=library2` — the Library module's *views*: the grid's
/// scroll position surviving a trip through Develop untouched, and the loupe.
///
/// Both are driven through the real window with real keystrokes and the real
/// `NSScrollView`, because both are things no unit test can see: "the grid did
/// not move" is a claim about a scroll view that laid itself out, and "the
/// loupe is filling the content area" is a fact about views.
extension SelfTest {
    // MARK: - The grid's scroll position

    /// The `NSScrollView` the library grid is drawn in, found through a cell of
    /// it: a `ClickCatcher` is a real `NSView` inside the scrolled content, and
    /// `enclosingScrollView` is the rest. `nil` when there is no grid in the
    /// window at all — which is what a rebuilt scroll view looks like on the
    /// pass it is missing.
    static func gridScrollView(_ app: AppModel) -> NSScrollView? {
        for id in app.visiblePhotoIDs {
            if let scroll = cellView(cellID(id))?.enclosingScrollView { return scroll }
        }
        return nil
    }

    /// Where the grid is scrolled to right now — the reading its own
    /// `ScrollView` publishes, which is the only claim the app makes about its
    /// position (see `AppModel.libraryGridScroll`).
    static func gridScrollOffset(_ app: AppModel) -> Double? {
        app.libraryGridScroll?.offset
    }

    /// Scrolls the grid the way a scroll wheel does: by moving the clip view.
    ///
    /// `y` is the distance into the content, the same number `gridScrollOffset`
    /// reports, so the clip view's own top inset is taken off on the way in —
    /// see `GridScrollMetrics`.
    @discardableResult
    static func scrollGrid(_ app: AppModel, to y: Double) -> Bool {
        guard let scroll = gridScrollView(app) else {
            log("library self-test: the grid has no scroll view to scroll")
            return false
        }
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: y - clip.contentInsets.top))
        scroll.reflectScrolledClipView(clip)
        return true
    }

    /// How far the grid *can* scroll: zero when everything fits.
    static func gridScrollRange(_ app: AppModel) -> Double {
        app.libraryGridScroll?.range ?? 0
    }

    /// A cell of the grid whose middle is under the **develop** canvas, so a
    /// click aimed at it can only land on the canvas or on the grid — and not
    /// on the develop sidebar, where it would move a slider.
    static func cellUnderDevelopCanvas(_ app: AppModel, besides excluded: Int64) -> Int64? {
        guard let canvas = findCanvas() else { return nil }
        let area = canvas.convert(canvas.bounds, to: nil)
        return app.visiblePhotoIDs.first { id in
            guard id != excluded, let cell = cellView(cellID(id)), cell.window != nil else {
                return false
            }
            let frame = cell.convert(cell.bounds, to: nil)
            return area.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    /// Whether a cell is inside the part of the grid the user can see.
    static func cellIsInView(_ id: Int64) -> Bool {
        guard let cell = cellView(cellID(id)), let scroll = cell.enclosingScrollView,
              let document = scroll.documentView else { return false }
        return scroll.documentVisibleRect.intersects(cell.convert(cell.bounds, to: document))
    }

    /// Whether a cell is *wholly* on screen. The stronger question, and the one
    /// a test that wants to click a cell has to ask: a cell hanging half out of
    /// the clip view has its middle outside it, and the click aimed there is
    /// clipped away before it reaches anything.
    static func cellIsWhollyInView(_ id: Int64) -> Bool {
        guard let cell = cellView(cellID(id)), let scroll = cell.enclosingScrollView,
              let document = scroll.documentView else { return false }
        return scroll.documentVisibleRect.contains(cell.convert(cell.bounds, to: document))
    }

    // MARK: Every offset the grid ever had

    /// Every distinct offset the grid was left at, in order, one sample per
    /// turn of the run loop. `noGrid` stands for a pass in which there was no
    /// grid in the window at all.
    ///
    /// Sampled from a `CFRunLoopObserver` on `beforeWaiting` — the point at
    /// which AppKit has finished laying out and drawing and the window server
    /// is about to composite — rather than from the clip view's
    /// bounds-did-change notification, which AppKit coalesces through
    /// `NSNotificationQueue` and delivers *later* (measured: the value read in
    /// the notification is whatever the clip view has settled on by delivery
    /// time, not what it had when it moved). One sample per pass is one sample
    /// per frame the user could have seen, which is exactly the claim.
    ///
    /// What is sampled is the grid's own reading of itself — the model field
    /// `onScrollGeometryChange` writes — and that reading goes `nil` when the
    /// grid leaves the window, so the transition under test (a scroll view
    /// rebuilt from scratch) shows up in the log as `noGrid` rather than
    /// vanishing from it.
    static var gridOffsetLog: [Double] = []
    private static var gridOffsetSampler: CFRunLoopObserver?

    /// What the log holds for a pass with no grid in the window.
    static let noGrid = -1.0

    static func startRecordingGridOffset(_ app: AppModel) {
        stopRecordingGridOffset()
        gridOffsetLog = []
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { _, _ in
            let now = gridScrollOffset(app) ?? noGrid
            guard gridOffsetLog.last != now else { return }
            gridOffsetLog.append(now)
        }
        gridOffsetSampler = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    static func stopRecordingGridOffset() {
        if let gridOffsetSampler {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), gridOffsetSampler, .commonModes)
        }
        gridOffsetSampler = nil
    }

    /// Feature 1, end to end: scroll the grid, go to Develop, come back, and be
    /// at the same offset — with nothing in between.
    ///
    /// The claim is stronger than "it ends up where it was". The grid is never
    /// taken out of the window (`RootView`), so the offset is not restored, it
    /// simply never changes: the recorder above says so by listing every value
    /// the clip view took between `d` and the grid being back, and the scroll
    /// view's own identity says the view was not rebuilt under it. A restore —
    /// however fast — puts a 0 in that list, and that 0 is the flash the user
    /// sees.
    ///
    /// The thumbnails are pushed to their largest size first, for the dullest
    /// of reasons: twelve frames at the default size all fit in the window, and
    /// a grid with nowhere to scroll cannot prove anything about scrolling.
    static func runGridScrollChecks(app: AppModel, window: NSWindow,
                                    check: @escaping (Bool, String) -> Void,
                                    failures: @escaping () -> [String]) {
        phase("grid scroll")
        guard let subject = app.catalog.photos.first(where: { $0.url != nil })?.id else {
            check(false, "a photo with a file to develop")
            finishLibrary(failures())
        }
        var noted: Double = 0
        var scrollViewInGrid: ObjectIdentifier?

        let steps: [() -> Void] = [
            {
                check(clickCell(cellID(subject)), "clicked the cell to come back to")
                app.libraryThumbnailSize = ImportModel.maximumThumbnailSize
            },
            {
                check(gridScrollView(app) != nil,
                      "the grid is drawn in a real NSScrollView, which is what its "
                          + "position can be read off")
                let range = gridScrollRange(app)
                check(range > 100,
                      "…with somewhere to scroll at \(Int(app.libraryThumbnailSize)) pt "
                          + "(\(Int(range)) pt of travel)")
                check(scrollGrid(app, to: min(300, range)), "scrolled the grid down")
            },
            {
                noted = gridScrollOffset(app) ?? 0
                scrollViewInGrid = gridScrollView(app).map(ObjectIdentifier.init)
                check(noted > 10, "the grid is scrolled down (\(noted) pt)")
                check(app.highlightedPhotoIDs == [subject],
                      "…with the same cell still selected")
                startRecordingGridOffset(app)
                sendKey("d", modifiers: [], window: window, virtualKey: 2)
            },
            {
                check(app.mode == .develop, "d left for the develop view")
                check(app.currentPhotoID == subject, "…on the selected photo")
                check(findCanvas() != nil, "…and the develop canvas is in the window")
                // The grid is still there, laid out, at the offset it was left
                // at — which is the whole mechanism. A scroll view that had been
                // torn down would answer nothing at all here.
                check(gridScrollView(app).map(ObjectIdentifier.init) == scrollViewInGrid,
                      "…while the grid's scroll view is the very same object, not a "
                          + "rebuilt one")
                let held = gridScrollOffset(app) ?? -1
                check(abs(held - noted) < 0.001,
                      "…still holding the offset itself (\(held) pt, was \(noted) pt)")
                check(gridScrollRange(app) > 100,
                      "…and still laid out at its full height, so SwiftUI did not "
                          + "collapse it (\(Int(gridScrollRange(app))) pt of travel)")
                // Nothing behind the canvas may take a click. A cell of the
                // hidden grid is a `ClickCatcher`, a real `NSView` that takes
                // mouse-downs, so `.allowsHitTesting(false)` on the Library has
                // to actually reach it.
                let selectionInDevelop = app.highlightedPhotoIDs
                if let other = cellUnderDevelopCanvas(app, besides: subject),
                   let cell = cellView(cellID(other)) {
                    let point = cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY),
                                             to: nil)
                    let hit = searchRoot(of: window)?.hitTest(point)
                    check(!(hit is ClickCatcherView),
                          "the window's hit test over a hidden cell answers the develop "
                              + "view, not the grid's click catcher "
                              + "(\(hit.map { String(describing: type(of: $0)) } ?? "nothing"))")
                    _ = clickCell(cellID(other))
                    check(app.highlightedPhotoIDs == selectionInDevelop,
                          "…and a real click there leaves the grid's selection alone "
                              + "(\(app.highlightedPhotoIDs) vs \(selectionInDevelop))")
                    check(app.mode == .develop,
                          "…and does not change modules (\(app.mode.rawValue))")
                } else {
                    check(false, "a cell of the hidden grid under the develop canvas to click")
                }
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
        ]

        runSteps(steps, model: app) {
            let now = gridScrollOffset(app) ?? -1
            stopRecordingGridOffset()
            check(app.mode == .library, "g came back to the grid")
            check(findCanvas() == nil, "…and the develop canvas left the window")
            check(gridScrollView(app).map(ObjectIdentifier.init) == scrollViewInGrid,
                  "…in the same scroll view it went to Develop in")
            check(now == noted,
                  "…at bit-identical the offset it was left at (\(now) pt, was \(noted) pt)")
            // The regression test for the flash itself.
            let strays = gridOffsetLog.filter { $0 != noted }
            check(strays.isEmpty,
                  "…and the clip view never took any other value on the way "
                      + "(\(gridOffsetLog.count) change(s) recorded, strays \(strays))")
            check(!gridOffsetLog.contains(0),
                  "…in particular never 0, which is the frame of grid-at-the-top the "
                      + "user was seeing")
            check(app.highlightedPhotoIDs == [subject],
                  "…with the same photo selected (\(app.highlightedPhotoIDs))")
            check(app.libraryScrollTarget == nil,
                  "…and no scroll-to-a-cell was asked for, which would have moved it "
                      + "(\(app.libraryScrollTarget.map { "\($0)" } ?? "none"))")
            writeScreenshot(of: window, named: "selftest-library-scrolled.png")
            runLoupeScrollChecks(app: app, window: window, check: check, failures: failures)
        }
    }

    /// The same claim for the Library's *other* switch: `e` into the loupe and
    /// `g` back out, on a grid that is scrolled well down.
    ///
    /// Coming back from the loupe is not the same problem as coming back from
    /// Develop. The loupe's photo may be one the arrows walked to, so the grid
    /// legitimately scrolls it into view — the offset is allowed to *change*.
    /// What it is not allowed to do is take any other value on the way: a grid
    /// rebuilt at zero and corrected a frame later is the flash, whether the
    /// correction lands on the old offset or on a new one.
    static func runLoupeScrollChecks(app: AppModel, window: NSWindow,
                                     check: @escaping (Bool, String) -> Void,
                                     failures: @escaping () -> [String]) {
        phase("loupe scroll")
        var noted: Double = 0
        var scrollViewInGrid: ObjectIdentifier?
        var subject: Int64 = 0

        let steps: [() -> Void] = [
            {
                let range = gridScrollRange(app)
                check(scrollGrid(app, to: min(300, range)), "scrolled the grid well down again")
            },
            {
                noted = gridScrollOffset(app) ?? 0
                scrollViewInGrid = gridScrollView(app).map(ObjectIdentifier.init)
                check(noted > 10, "the grid is scrolled down (\(noted) pt)")
                // The *last* cell on screen at this offset, not the first: a
                // grid that comes back at zero would still have the first one
                // in view, so it would prove nothing.
                guard let onScreen = app.visiblePhotoIDs
                    .last(where: { cellIsWhollyInView($0) }) else {
                    check(false, "a cell in view to open in the loupe")
                    finishLibrary(failures())
                }
                subject = onScreen
                check(clickCell(cellID(subject)), "clicked a cell that is in view")
                startRecordingGridOffset(app)
                sendKey("e", modifiers: [], window: window, virtualKey: 14)
            },
            {
                check(app.libraryViewMode == .loupe, "e opened the loupe")
                check(app.loupePhotoID == subject, "…on that cell's photo")
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
        ]

        runSteps(steps, model: app) {
            let now = gridScrollOffset(app) ?? -1
            stopRecordingGridOffset()
            check(app.libraryViewMode == .grid, "g came back to the grid")
            check(gridScrollView(app).map(ObjectIdentifier.init) == scrollViewInGrid,
                  "…in the same scroll view it went to the loupe in, not a rebuilt one")
            check(cellIsInView(subject), "…with the loupe's photo in view")
            // The regression test for the flash. The loupe opened on a cell the
            // grid was already showing and never walked, so there was nothing
            // to scroll to and nothing may have moved — not on the way in, not
            // on the way out, and not for one frame in between.
            check(now == noted,
                  "…at bit-identical the offset it left at (\(now) pt, was \(noted) pt)")
            let strays = gridOffsetLog.filter { $0 != noted }
            check(strays.isEmpty,
                  "…and the grid never held any other offset for a single frame "
                      + "(log \(gridOffsetLog), strays \(strays))")
            check(!gridOffsetLog.contains(noGrid),
                  "…and there was never a pass with no grid in the window at all, "
                      + "which is a scroll view being rebuilt (\(gridOffsetLog))")
            check(now > 10,
                  "…and the grid did not come back at the top (\(now) pt)")
            check(app.libraryScrollTarget == nil,
                  "…and no scroll-to-a-cell was asked for, because the loupe never "
                      + "walked off the cell it opened on "
                      + "(\(app.libraryScrollTarget.map { "\($0)" } ?? "none"))")
            writeScreenshot(of: window, named: "selftest-library-loupe-scrolled.png")
            // Back to the size and the position the rest of the run expects
            // to find the grid at.
            app.libraryThumbnailSize = ImportModel.defaultThumbnailSize
            scrollGrid(app, to: 0)
            settle(app) {
                runLoupeChecks(app: app, window: window, check: check, failures: failures)
            }
        }
    }

    // MARK: - The loupe over a development

    /// The loupe's other half of "as developed": a photo *with* a development is
    /// the real pipeline over development #1, at the decode's own resolution —
    /// not the camera's embedded picture, and not the grid's 512 px preview.
    ///
    /// Run in the `library` mode, straight after the same photo's grid preview
    /// has been checked, so the two share one witness: the mean luminance of the
    /// embedded preview the +2 EV development replaced. The witness is read off
    /// the **texture the canvas is drawing**, encoded back to sRGB so it is the
    /// same number the `CGImage` comparison produced — there is no `CGImage` in
    /// this path any more, which is the point of it.
    static func runDevelopedLoupeChecks(app: AppModel, window: NSWindow, subject: Int64,
                                        beforeLuminance: Double,
                                        check: @escaping (Bool, String) -> Void,
                                        then done: @escaping () -> Void) {
        phase("developed loupe")
        let steps: [() -> Void] = [
            {
                check(clickCell(cellID(subject)), "clicked the developed photo's cell")
                sendKey("e", modifiers: [], window: window, virtualKey: 14)
            },
            {
                check(app.libraryViewMode == .loupe && app.loupePhotoID == subject,
                      "e opened the loupe on the developed photo")
            },
        ]
        runSteps(steps, model: app) {
            waitForLoupeImage(app) {
                check(app.loupeIsFullResolution,
                      "the loupe built a picture of its own for it")
                let canvas = findLoupeCanvas()
                check(canvas != nil, "…on the real canvas, the one the develop view uses")
                let texture = canvas?.imageTexture ?? app.loupeTexture
                let edge = texture.map { max($0.width, $0.height) } ?? 0
                let photo = app.catalog.photo(id: subject)
                let full = max(photo?.width ?? 0, photo?.height ?? 0)
                check(app.loupeImageSize == app.previewSize && app.previewSize != .zero,
                      "…of the frame the decode produced, not a reduced copy "
                          + "(\(app.loupeImageSize) vs \(app.previewSize))")
                check(edge >= min(full, Int(max(app.previewSize.width,
                                                app.previewSize.height))),
                      "…at the file's own resolution (\(edge) px of \(full) px)")
                check(edge > PreviewBuilder.pixelSize,
                      "…which is more than the \(PreviewBuilder.pixelSize) px the grid holds")
                let luminance = texture.flatMap(meanEncodedLuminance) ?? 0
                check(luminance > beforeLuminance,
                      String(format: "…and it is the +2 EV development, not the camera's "
                             + "picture (%.4f > %.4f)", luminance, beforeLuminance))
                // The develop view is not re-decoding anything to show the same
                // photo: the loupe put it through the very same render loop.
                check(app.currentPhotoID == subject,
                      "…and the render loop is on that photo, so d is free")
                checkLoupeIsEDR(check: check)
                writeScreenshot(of: window, named: "selftest-loupe-developed.png")
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
                settle(app, then: done)
            }
        }
    }

    /// The loupe's drawable is configured exactly as the develop canvas's is:
    /// half-float, extended **linear** sRGB, extended-range content declared.
    /// Without all three the loupe would be an SDR surface that happens to be
    /// float, and an HDR development would be clamped to SDR white on it.
    static func checkLoupeIsEDR(check: (Bool, String) -> Void) {
        guard let canvas = findLoupeCanvas(), let layer = canvas.layer as? CAMetalLayer else {
            check(false, "the loupe's canvas has a CAMetalLayer to check for EDR")
            return
        }
        check(canvas.colorPixelFormat == .rgba16Float,
              "the loupe's drawable is rgba16Float, so values above SDR white survive "
                  + "(\(canvas.colorPixelFormat.rawValue))")
        check(layer.colorspace?.name == CGColorSpace.extendedLinearSRGB,
              "…tagged extended linear sRGB, so the window server owns the transfer "
                  + "function (\(layer.colorspace?.name.map { $0 as String } ?? "untagged"))")
        check(layer.wantsExtendedDynamicRangeContent,
              "…with extended dynamic range asked for, which is what reaches the "
                  + "panel's headroom")
    }

    /// Rec.709 luminance of a display-linear `rgba16Float` texture, **sRGB
    /// encoded** first — the same number `meanLuminance(_: CGImage)` produces
    /// for the same picture, so the two are comparable.
    static func meanEncodedLuminance(_ texture: MTLTexture) -> Double? {
        guard let image = try? TextureReadback.read(texture) else { return nil }
        func encode(_ v: Float) -> Double {
            let x = min(max(Double(v), 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        var total = 0.0
        for i in stride(from: 0, to: image.pixels.count, by: 4) {
            total += 0.2126 * encode(image.pixels[i])
                + 0.7152 * encode(image.pixels[i + 1])
                + 0.0722 * encode(image.pixels[i + 2])
        }
        return total / Double(image.width * image.height)
    }

    // MARK: - The title bar's leading items

    /// Import and the module picker, on screen.
    ///
    /// A `NavigationSplitView` puts a tracking separator in the toolbar that
    /// lines the bar's content up with the sidebar's divider, and a column that
    /// collapses out from under it is exactly the case that can leave the
    /// leading buttons stranded — shoved along the bar, or under the traffic
    /// lights. So the loupe measures them and compares.
    static func leadingFrames() -> [String: NSRect] {
        var frames: [String: NSRect] = [:]
        for name in ["toolbar-import", "mode-picker"] {
            if let frame = controlFrame(named: name) { frames[name] = frame }
        }
        return frames
    }

    static func describeFrames(_ frames: [String: NSRect]) -> String {
        frames.keys.sorted().map { "\($0)=\(frames[$0]!)" }.joined(separator: " ")
    }

    // MARK: - The loupe

    /// Feature 2: Lightroom's Library loupe, driven by its own keys.
    ///
    /// `e` and Return open it, the arrows walk the filtered order and stop at
    /// the ends, the colour keys still label the photo on screen, `g` and Esc
    /// come back to the grid with that photo selected and in view, `d` develops
    /// it and `e` from the develop view comes back to it.
    static func runLoupeChecks(app: AppModel, window: NSWindow,
                               check: @escaping (Bool, String) -> Void,
                               failures: @escaping () -> [String]) {
        phase("loupe")
        // A photo the grid could actually draw, with a neighbour after it: the
        // loupe's first frame is the grid's own preview, and the walk needs
        // somewhere to walk to.
        let drawable = app.visiblePhotos.filter { app.previews.cached($0) != nil }.map(\.id)
        let order = app.visiblePhotoIDs
        guard let subject = drawable.first(where: { id in
            guard let index = order.firstIndex(of: id), index + 1 < order.count else { return false }
            return drawable.contains(order[index + 1])
        }), let index = order.firstIndex(of: subject) else {
            check(false, "two neighbouring photos the grid has pictures of")
            finishLibrary(failures())
        }
        let total = order.count
        var framesInGrid: [String: NSRect] = [:]

        let steps: [() -> Void] = [
            {
                check(clickCell(cellID(subject)), "clicked a cell to open in the loupe")
                check(app.highlightedPhotoIDs == [subject], "…and it is the highlight")
                framesInGrid = leadingFrames()
                // 1. `e` is Lightroom's loupe key — and the picture is there in
                //    the same turn of the run loop it is pressed in, because it
                //    is the one the grid already had.
                sendKey("e", modifiers: [], window: window, virtualKey: 14)
                check(app.libraryViewMode == .loupe, "e opened the loupe")
                check(app.loupeTexture != nil,
                      "…with a picture in it immediately, before any render")
                check(!app.loupeIsFullResolution,
                      "…the grid's own 512 px preview, standing in")
            },
            {
                check(app.mode == .library,
                      "…which is a Library view, so the module did not change "
                          + "(\(app.mode.rawValue))")
                check((control(named: "mode-picker") as? NSSegmentedControl)?.selectedSegment == 0,
                      "…and the toolbar's picker is still on Library")
                check(probeView("loupe") != nil, "…the loupe is in the window")
                check(app.loupePhotoID == subject, "…on the highlighted photo")
                check(findLoupeCanvas() != nil,
                      "…drawing the real canvas, the same view the develop view uses")
                check(findCanvas() == nil, "…and the develop canvas is not in the window")
                // 1a. The Folders panel gets out of the way: Lightroom's loupe
                //     gives the photo the window. The *preference* is untouched,
                //     which is what `g` puts back.
                check(!app.isFolderSidebarShowing,
                      "the Folders panel is not showing in the loupe")
                check(app.isFolderSidebarVisible,
                      "…while the panel's own setting is untouched, so g can put it back")
                check(sidebarWidth(in: window) == 0,
                      "…and it is off the window (\(sidebarWidth(in: window)) pt wide)")
                // The leading toolbar items must not be dragged along by the
                // split view's tracking separator when the column collapses.
                check(isInTitleBar(probeView("toolbar-import"))
                          && isInTitleBar(probeView("mode-picker")),
                      "…without taking Import or the module picker out of the title bar")
                // They *do* slide leftwards, and should: the tracking separator
                // lines the bar up with the column divider, and with no column
                // there is nothing to clear. What must not happen is either of
                // them ending up under the traffic lights, off the bar's line,
                // or out of order.
                let inLoupe = leadingFrames()
                check(inLoupe.count == framesInGrid.count,
                      "…and both of them are still on screen "
                          + "(\(describeFrames(inLoupe)))")
                if let import0 = framesInGrid["toolbar-import"],
                   let import1 = inLoupe["toolbar-import"],
                   let picker1 = inLoupe["mode-picker"] {
                    check(import1.minX <= import0.minX,
                          "…having moved into the space the column left, not out of it "
                              + "(\(import1.minX), was \(import0.minX))")
                    check(sameLine(import1, import0),
                          "…on the bar's own line still (\(import1) vs \(import0))")
                    check(picker1.minX >= import1.maxX,
                          "…and in the same order (Import ends \(import1.maxX), "
                              + "the picker starts \(picker1.minX))")
                    check(import1.size == import0.size && inLoupe["mode-picker"]?.size
                              == framesInGrid["mode-picker"]?.size,
                          "…at their own sizes, not squeezed")
                }
                if let zoom = window.standardWindowButton(.zoomButton),
                   let lights = screenFrame(of: zoom),
                   let leading = inLoupe["toolbar-import"] {
                    check(leading.minX >= lights.maxX,
                          "…and Import still clears the traffic lights "
                              + "(\(leading.minX) vs \(lights.maxX))")
                }
                // 2. The status bar swaps the grid's count for Lightroom's
                //    position in the filtered list.
                check(app.loupePositionLabel == "\(index + 1) / \(total)",
                      "the bar says where this photo is (got '\(app.loupePositionLabel)')")
                check(controlFrame(named: "loupe-position") != nil, "…and draws it")
                check(controlFrame(named: "library-count") == nil,
                      "…in place of the grid's photo count")
                check(controlFrame(named: "library-thumbnail-size") == nil,
                      "…and the thumbnail-size slider is gone with the thumbnails")
                let name = controlFrame(named: "loupe-name")
                check(name != nil, "the bar names the file")
                check(app.loupeName == app.catalog.photo(id: subject)?.originalName,
                      "…the one in the loupe (got '\(app.loupeName)')")
                check(probeView("loupe-image") != nil, "the picture is drawn in the window")
                check(app.loupeMessage == nil,
                      "…with no error over it (\(app.loupeMessage ?? "none"))")
            },
        ]

        runSteps(steps, model: app) {
            waitForLoupeImage(app) {
                check(app.loupeIsFullResolution,
                      "…and a loupe-sized picture replaced it")
                // How big it is depends on the camera: an undeveloped photo is
                // its own embedded preview, and cameras embed everything from a
                // 640 px JPEG to a full-size one. What must be true is that the
                // loupe is not still showing the grid's thumbnail.
                let size = app.loupeTexture.map { max($0.width, $0.height) } ?? 0
                check(size >= PreviewBuilder.pixelSize,
                      "…at least the \(PreviewBuilder.pixelSize) px the grid holds "
                          + "(\(size) px)")
                check(findLoupeCanvas()?.imageTexture === app.loupeTexture,
                      "…and it is what the canvas is drawing, pushed straight at it")
                if let canvas = findLoupeCanvas() {
                    log("library self-test: loupe canvas transform=\(canvas.transform) "
                        + "texture=\(canvas.imageTexture.map { "\($0.width)x\($0.height)" } ?? "none") "
                        + "bounds=\(canvas.bounds)")
                }
                // The canvas fits the *photo's* frame, not the texture's: a
                // camera that embeds a 640 px preview of a 50 MP frame must
                // still fill the window, not put a postage stamp in the middle
                // of it.
                let canvas = findLoupeCanvas()
                let photo = app.catalog.photo(id: subject)
                let longEdge = max(photo?.width ?? 0, photo?.height ?? 0)
                let frameEdge = Int(max(app.loupeImageSize.width, app.loupeImageSize.height))
                check(canvas?.transform.imageSize == app.loupeImageSize,
                      "…and the canvas is fitting the frame the model gave it "
                          + "(\(canvas.map { "\($0.transform.imageSize)" } ?? "no canvas") "
                          + "vs \(app.loupeImageSize))")
                check(frameEdge == longEdge,
                      "…which is the photo's own long edge, whatever resolution the "
                          + "picture of it is (\(frameEdge) of \(longEdge))")
                check(canvas?.transform.isFit == true, "…fitted to the window")
                checkLoupeIsEDR(check: check)
                runLoupeNavigationChecks(app: app, window: window, subject: subject,
                                         index: index, order: order,
                                         check: check, failures: failures)
            }
        }
    }

    /// Polls until the loupe-resolution picture has landed. Bounded on its own
    /// as well as by the run's deadline: a photo whose picture never arrives is
    /// a failed check, not a run that reports nothing.
    static func waitForLoupeImage(_ app: AppModel, attemptsLeft: Int = 300,
                                  then body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if !app.loupeIsFullResolution, attemptsLeft > 0, Date() < deadline {
                waitForLoupeImage(app, attemptsLeft: attemptsLeft - 1, then: body)
            } else {
                body()
            }
        }
    }

    /// The rest of the loupe: the arrows, the colour keys, and the four ways in
    /// and out of it.
    static func runLoupeNavigationChecks(app: AppModel, window: NSWindow, subject: Int64,
                                         index: Int, order: [Int64],
                                         check: @escaping (Bool, String) -> Void,
                                         failures: @escaping () -> [String]) {
        let next = order[index + 1]
        let total = order.count
        let first = order[0]
        // Where the title bar's leading items are *while the loupe has the
        // window*, so that bringing the Folders panel back can be shown not to
        // move them either.
        let framesInLoupe = leadingFrames()

        let steps: [() -> Void] = [
            {
                // 4. The right arrow walks the filtered order.
                sendKey("", modifiers: [], window: window, virtualKey: 124, viaQueue: true)
            },
            {
                check(app.loupePhotoID == next,
                      "the right arrow moved on to the next photo "
                          + "(\(app.loupePhotoID.map { "\($0)" } ?? "none"))")
                check(app.loupePositionLabel == "\(index + 2) / \(total)",
                      "…and the position moved with it (got '\(app.loupePositionLabel)')")
                check(app.highlightedPhotoIDs == [next],
                      "…and the grid's selection followed, so `g` comes back to it")
                // 4. The colour keys work on the photo in the loupe.
                sendKey("8", modifiers: [], window: window, virtualKey: 28)
            },
            {
                check(app.catalog.photo(id: next)?.color == .green,
                      "8 turned the photo in the loupe green")
                check(storedColor(next) == .green,
                      "…and in the database (got \(describe(storedColor(next))))")
                check(app.catalog.photo(id: subject)?.color == .unlabeled,
                      "…and only that one (the photo before it is unlabelled)")
                // 5. Up and down do nothing at all in the loupe.
                sendKey("", modifiers: [], window: window, virtualKey: 125, viaQueue: true)
            },
            {
                check(app.loupePhotoID == next && app.libraryViewMode == .loupe,
                      "the down arrow does nothing in the loupe "
                          + "(\(app.loupePhotoID.map { "\($0)" } ?? "none"))")
                writeScreenshot(of: window, named: "selftest-loupe.png")
                // 6. `g` back to the grid, on that photo, with it in view.
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
            {
                check(app.libraryViewMode == .grid && app.mode == .library,
                      "g came back to the grid")
                check(probeView("loupe") == nil, "…and the loupe is out of the window")
                check(app.highlightedPhotoIDs == [next],
                      "…with the loupe's photo selected (\(app.highlightedPhotoIDs))")
                check(controlFrame(named: "library-count") != nil,
                      "…and the grid's photo count back in the status bar")
                check(cellIsInView(next),
                      "…and its cell scrolled into view")
                // 6a. …and the Folders panel is back, because it was showing
                //     when the loupe took the window.
                check(app.isFolderSidebarShowing,
                      "…and the Folders panel came back with it")
                check(sidebarWidth(in: window) > 0,
                      "…to its own width (\(sidebarWidth(in: window)) pt)")
                check(!sidebarRows(in: window).isEmpty,
                      "…with its rows drawn again "
                          + "(\(sidebarRows(in: window).count) rows)")
                let backInGrid = leadingFrames()
                check(backInGrid.count == framesInLoupe.count,
                      "…and the title bar's leading items are all still there "
                          + "(\(describeFrames(backInGrid)))")
                if let wide = backInGrid["toolbar-import"],
                   let narrow = framesInLoupe["toolbar-import"] {
                    check(wide.minX >= narrow.minX && sameLine(wide, narrow),
                          "…back out along the bar to make room for the column, on the "
                              + "same line (\(wide.minX), was \(narrow.minX))")
                }
                // 6b. The other direction: a panel the user had *hidden* must
                //     still be hidden after a trip through the loupe.
                sendKey("s", modifiers: [.command, .option], window: window,
                        virtualKey: 1, viaQueue: true)
            },
            {
                check(!app.isFolderSidebarVisible, "Opt-Cmd-S hid the Folders panel")
                sendKey("e", modifiers: [], window: window, virtualKey: 14)
            },
            {
                check(app.libraryViewMode == .loupe, "e opened the loupe with the panel hidden")
                check(!app.isFolderSidebarShowing, "…and the panel is still not showing")
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
            {
                check(app.libraryViewMode == .grid, "g came back to the grid")
                check(!app.isFolderSidebarShowing,
                      "…and the panel stayed hidden, which is how it was left")
                check(sidebarWidth(in: window) == 0,
                      "…and it is still off the window (\(sidebarWidth(in: window)) pt)")
                sendKey("s", modifiers: [.command, .option], window: window,
                        virtualKey: 1, viaQueue: true)
            },
            {
                check(app.isFolderSidebarShowing,
                      "Opt-Cmd-S put the panel back for the rest of the run")
                // 7. Return is Lightroom's other way in.
                sendKey("", modifiers: [], window: window, virtualKey: 36, viaQueue: true)
            },
            {
                check(app.libraryViewMode == .loupe, "Return opened the loupe again")
                check(app.loupePhotoID == next, "…on the selected photo")
                // 8. Esc is Lightroom's way out of any secondary view.
                sendKey("", modifiers: [], window: window, virtualKey: 53, viaQueue: true)
            },
            {
                check(app.libraryViewMode == .grid, "Esc came back to the grid")
                check(app.highlightedPhotoIDs == [next], "…with the photo still selected")
                // 9. The ends of the walk: the first photo, left arrow, and
                //    nothing moves — Lightroom does not wrap.
                check(clickCell(cellID(first)), "clicked the first cell")
                sendKey("e", modifiers: [], window: window, virtualKey: 14)
            },
            {
                check(app.loupePhotoID == first, "the loupe is on the first photo")
                sendKey("", modifiers: [], window: window, virtualKey: 123, viaQueue: true)
            },
            {
                check(app.loupePhotoID == first,
                      "the left arrow stops at the first photo rather than wrapping "
                          + "(\(app.loupePhotoID.map { "\($0)" } ?? "none"))")
                check(app.loupePositionLabel == "1 / \(total)",
                      "…and the position says so (got '\(app.loupePositionLabel)')")
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
            {
                // 10. `d` develops the photo in the loupe.
                check(clickCell(cellID(subject)), "clicked the subject's cell in the grid")
                sendKey("e", modifiers: [], window: window, virtualKey: 14)
            },
            {
                check(app.loupePhotoID == subject, "the loupe is back on the subject")
                sendKey("d", modifiers: [], window: window, virtualKey: 2)
            },
            {
                check(app.mode == .develop, "d left the loupe for the develop view")
                check(app.currentPhotoID == subject,
                      "…on the photo the loupe was showing "
                          + "(\(app.currentPhotoID.map { "\($0)" } ?? "none"))")
                check(findCanvas() != nil, "…and the canvas is in the window")
                // 11. …and `e` comes back to the loupe on it, as in Lightroom.
                sendKey("e", modifiers: [], window: window, virtualKey: 14)
            },
            {
                check(app.mode == .library && app.libraryViewMode == .loupe,
                      "e came back from Develop to the loupe "
                          + "(\(app.mode.rawValue)/\(app.libraryViewMode.rawValue))")
                check(app.loupePhotoID == subject,
                      "…on the photo that was being developed")
                check(probeView("loupe") != nil, "…and the loupe is in the window again")
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
        ]

        runSteps(steps, model: app) {
            check(app.libraryViewMode == .grid, "g left the loupe for the rest of the run")
            runLoupeZoomChecks(app: app, window: window, check: check, failures: failures)
        }
    }

    // MARK: - Zoom

    /// Feature 3: the loupe zooms, exactly as the develop view does.
    ///
    /// `0` fits, `1` is 100 %, a double-click toggles between the two, and the
    /// status bar says which. All of it is read off the **canvas's own
    /// transform** — the thing the shader inverts to draw with — rather than off
    /// the model, so a zoom the model believes in but the view does not fails.
    static func runLoupeZoomChecks(app: AppModel, window: NSWindow,
                                   check: @escaping (Bool, String) -> Void,
                                   failures: @escaping () -> [String]) {
        phase("loupe zoom")
        // A photo big enough to have somewhere to zoom *to*: fit has to be below
        // 100 %, or every one of these checks is trivially satisfied by an image
        // that is already at 1:1.
        let candidates = app.visiblePhotos
            .filter { $0.url != nil }
            .sorted { max($0.width ?? 0, $0.height ?? 0) > max($1.width ?? 0, $1.height ?? 0) }
        guard let subject = candidates.first?.id else {
            check(false, "a photo to zoom in the loupe")
            finishLibrary(failures())
        }
        var fitZoom: Double = 0
        var fitFrame: NSRect = .zero

        let steps: [() -> Void] = [
            {
                check(clickCell(cellID(subject)), "clicked the biggest photo's cell")
                sendKey("e", modifiers: [], window: window, virtualKey: 14)
            },
            {
                check(app.loupePhotoID == subject, "e opened the loupe on it")
            },
        ]

        runSteps(steps, model: app) {
            waitForLoupeImage(app) {
                guard let canvas = findLoupeCanvas() else {
                    check(false, "the loupe's canvas to zoom")
                    finishLibrary(failures())
                }
                fitZoom = canvas.transform.zoom
                check(canvas.transform.isFit,
                      String(format: "the loupe opens fitted (%.1f %%)",
                             canvas.transform.zoomPercent))
                check(fitZoom < 1,
                      String(format: "…below 100 %%, so 1:1 is somewhere to go (%.3f)", fitZoom))
                check(abs(app.zoomPercent - canvas.transform.zoomPercent) < 0.01,
                      String(format: "…and the status bar's percentage is the canvas's own "
                             + "(%.1f vs %.1f)", app.zoomPercent, canvas.transform.zoomPercent))
                fitFrame = controlFrame(named: "loupe-zoom") ?? .zero
                check(fitFrame != .zero, "…drawn in the status bar")
                check(controlFrame(named: "library-count") == nil,
                      "…where the grid's count is not")
                runLoupeZoomKeyChecks(app: app, window: window, subject: subject,
                                      fitZoom: fitZoom, fitFrame: fitFrame,
                                      check: check, failures: failures)
            }
        }
    }

    static func runLoupeZoomKeyChecks(app: AppModel, window: NSWindow, subject: Int64,
                                      fitZoom: Double, fitFrame: NSRect,
                                      check: @escaping (Bool, String) -> Void,
                                      failures: @escaping () -> [String]) {
        var oneToOneFrame: NSRect = .zero

        let steps: [() -> Void] = [
            {
                // 1 — Lightroom's 1:1, and the develop view's own key for it.
                sendKey("1", modifiers: [], window: window, virtualKey: 18, viaQueue: true)
            },
            {
                let t = findLoupeCanvas()?.transform
                check(t?.zoom == 1,
                      String(format: "1 took the loupe to 100 %% (%.3f, was %.3f)",
                             t?.zoom ?? -1, fitZoom))
                check(abs(app.zoomPercent - 100) < 0.01,
                      String(format: "…and the status bar says 100 %% (%.1f)", app.zoomPercent))
                oneToOneFrame = controlFrame(named: "loupe-zoom") ?? .zero
                // The label is `.fixedSize()`, so it is as wide as its text: a
                // percentage with a different number of digits is a different
                // rectangle. When the two happen to be the same length there is
                // nothing to see, and the number above is the check.
                let fitText = String(format: "%.0f%%", fitZoom * 100)
                if fitText.count != "100%".count {
                    check(abs(oneToOneFrame.width - fitFrame.width) > 0.5,
                          "…redrawn at a different width, so the label follows the zoom "
                              + "('\(fitText)' \(fitFrame.width) pt vs '100%' "
                              + "\(oneToOneFrame.width) pt)")
                }
                writeScreenshot(of: window, named: "selftest-loupe-1-1.png")
                // 0 — back to fit.
                sendKey("0", modifiers: [], window: window, virtualKey: 29, viaQueue: true)
            },
            {
                let t = findLoupeCanvas()?.transform
                check(t?.isFit == true,
                      String(format: "0 fitted it again (%.3f)", t?.zoom ?? -1))
                check(abs((t?.zoom ?? 0) - fitZoom) < 1e-6,
                      "…at the zoom it opened at")
                // A double-click is Lightroom's mouse way to the same pair, and
                // it zooms *at the point clicked*.
                check(doubleClickLoupe(inset: 0.25), "double-clicked the loupe")
            },
            {
                let t = findLoupeCanvas()?.transform
                check(t?.zoom == 1,
                      String(format: "a double-click toggled fit -> 1:1 (%.3f)", t?.zoom ?? -1))
                check(doubleClickLoupe(inset: 0.25), "double-clicked it again")
            },
            {
                let t = findLoupeCanvas()?.transform
                check(t?.isFit == true,
                      String(format: "…and again toggled 1:1 -> fit (%.3f)", t?.zoom ?? -1))
                // Panning: a plain scroll moves the frame, which only means
                // anything while there is something off the edge to move to.
                sendKey("1", modifiers: [], window: window, virtualKey: 18, viaQueue: true)
            },
            {
                let before = findLoupeCanvas()?.transform.center ?? .zero
                scrollLoupe(deltaY: -120)
                let after = findLoupeCanvas()?.transform.center ?? .zero
                check(after != before,
                      "a scroll pans the zoomed loupe (\(before) -> \(after))")
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
        ]

        runSteps(steps, model: app) {
            check(app.libraryViewMode == .grid, "g came back to the grid")
            runLoupeHandoffChecks(app: app, window: window, check: check, failures: failures)
        }
    }

    /// A real double-click on the loupe's canvas, `inset` of the way in from its
    /// top-left corner.
    ///
    /// The **whole** double-click — click one and then click two, four events —
    /// because that is what the hardware sends and, since macOS 26, what
    /// `NSWindow.sendEvent` insists on. A lone `clickCount: 2` mouse-down is
    /// dropped on the floor there: AppKit tracks the click run itself now and
    /// will not deliver the second click of a run whose first click it never
    /// saw (measured — `hitTest` answers the canvas, `mouseDown` is never
    /// called). macOS 14 delivered it verbatim, which is why this used to be
    /// one pair.
    @discardableResult
    static func doubleClickLoupe(inset: Double) -> Bool {
        guard let canvas = findLoupeCanvas(), let window = canvas.window else {
            log("self-test: no loupe canvas to double-click")
            return false
        }
        let local = CGPoint(x: canvas.bounds.minX + canvas.bounds.width * inset,
                            y: canvas.bounds.minY + canvas.bounds.height * inset)
        let point = canvas.convert(local, to: nil)
        clickCounter += 1
        for clickCount in [1, 2] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: clickCounter, clickCount: clickCount, pressure: 1)
                else { return false }
                window.sendEvent(event)
            }
        }
        return true
    }

    /// A scroll on the loupe's canvas. Delivered to the view: `NSWindow`'s own
    /// dispatch hands scrolls to the scroll-view machinery, and the canvas is
    /// not in one.
    static func scrollLoupe(deltaY: Double) {
        guard let canvas = findLoupeCanvas(), let window = canvas.window else { return }
        let local = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        let event = LoupeScrollEvent(location: canvas.convert(local, to: nil),
                                     window: window, deltaY: CGFloat(deltaY))
        canvas.scrollWheel(with: event)
    }

    // MARK: - Develop and back, warm

    /// Feature 4: an edit made in Develop is in the loupe the instant `e` is
    /// pressed, at the canvas's own resolution — not the grid's 512 px preview
    /// catching up a second later.
    ///
    /// The claim is about *reuse*: the render loop already holds this photo's
    /// decode and a render of the edit that was just autosaved, so the loupe has
    /// nothing to do but point its canvas at them. The checks run in the same
    /// turn of the run loop as the keystroke, before any settle, because "a
    /// second later" is exactly the bug.
    static func runLoupeHandoffChecks(app: AppModel, window: NSWindow,
                                      check: @escaping (Bool, String) -> Void,
                                      failures: @escaping () -> [String]) {
        phase("loupe after an edit")
        // The cheapest file to decode that is still bigger than the grid's
        // preview: this phase opens it in Develop for real, and "the loupe is
        // not showing the 512 px preview" is only a claim about a photo that
        // *has* more than 512 px.
        guard let subject = app.visiblePhotos
            .filter({ $0.url != nil && max($0.width ?? 0, $0.height ?? 0)
                        > PreviewBuilder.pixelSize })
            .min(by: { $0.byteSize < $1.byteSize })?.id else {
            check(false, "a photo bigger than \(PreviewBuilder.pixelSize) px to develop")
            finishLibrary(failures())
        }
        var beforeFingerprint: Data?

        _ = clickCell(cellID(subject))
        sendKey("d", modifiers: [], window: window, virtualKey: 2)
        settle(app) {
            guard app.mode == .develop, app.currentPhotoID == subject else {
                check(false, "d opened the photo in develop")
                finishLibrary(failures())
            }
            beforeFingerprint = app.catalog.photo(id: subject)?.developmentFingerprint
            app.store.perform("Exposure") { $0.tone.exposure = 1.5 }
            waitForAutosave(app) {
                let fingerprint = app.catalog.photo(id: subject)?.developmentFingerprint
                check(fingerprint != nil && fingerprint != beforeFingerprint,
                      "the edit was autosaved as a new development fingerprint")
                let developTexture = findCanvas()?.imageTexture
                let decodeSize = app.previewSize
                check(developTexture != nil, "…and the develop canvas is showing its render")
                // The keystroke, and the assertions in the same turn.
                sendKey("e", modifiers: [], window: window, virtualKey: 14)
                check(app.libraryViewMode == .loupe && app.loupePhotoID == subject,
                      "e opened the loupe on the photo that was being edited")
                check(app.loupeIsFullResolution,
                      "…already showing its own picture, with no 512 px preview in between")
                check(app.loupeTexture === developTexture,
                      "…the very texture the develop view had just rendered, reused")
                check(app.loupeImageSize == decodeSize && decodeSize != .zero,
                      "…at the decode's own resolution (\(app.loupeImageSize) vs "
                          + "\(decodeSize))")
                let edge = app.loupeTexture.map { max($0.width, $0.height) } ?? 0
                check(edge > PreviewBuilder.pixelSize,
                      "…which is bigger than the grid's \(PreviewBuilder.pixelSize) px "
                          + "(\(edge) px)")
                check(!app.isDecoding,
                      "…and nothing was re-decoded to get there")
                settle(app) {
                    check(findLoupeCanvas()?.imageTexture === app.loupeTexture,
                          "the loupe's canvas has that texture on it")
                    checkLoupeIsEDR(check: check)
                    writeScreenshot(of: window, named: "selftest-loupe-edited.png")
                    sendKey("g", modifiers: [], window: window, virtualKey: 5)
                    settle(app) {
                        check(app.libraryViewMode == .grid,
                              "g left the loupe for the rest of the run")
                        runFolderChecks(app: app, window: window, check: check,
                                        failures: failures)
                    }
                }
            }
        }
    }
}

/// A scroll event with a window-relative location. `NSEvent(cgEvent:)` comes
/// back with a nil window and a *screen* point, which is the piece the canvas's
/// coordinate conversion needs; a subclass is the only way to hand
/// `scrollWheel(with:)` a point in the window.
private final class LoupeScrollEvent: NSEvent {
    private let loc: CGPoint
    private weak var win: NSWindow?
    private let dy: CGFloat

    init(location: CGPoint, window: NSWindow?, deltaY: CGFloat) {
        self.loc = location
        self.win = window
        self.dy = deltaY
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var type: NSEvent.EventType { .scrollWheel }
    override var locationInWindow: NSPoint { loc }
    override var window: NSWindow? { win }
    override var windowNumber: Int { win?.windowNumber ?? 0 }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var timestamp: TimeInterval { 0 }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { dy }
    override var deltaX: CGFloat { 0 }
    override var deltaY: CGFloat { dy }
    override var phase: NSEvent.Phase { [] }
    override var momentumPhase: NSEvent.Phase { [] }
}

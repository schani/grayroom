import AppKit
import CoreGraphics
import GrayroomCanvas
import GrayroomCore
import GrayroomLibrary
import GrayroomUI
import ImageIO
import Metal
import Observation
import UniformTypeIdentifiers

/// `GRAYROOM_SELFTEST=paint|undo|import|library|library2|loading swift run GrayroomApp <file.DNG>`
///
/// Whole-app checks, each in its own process: `paint` (a stroke drawn with real
/// mouse events), `undo` (Cmd-Z / Cmd-Shift-Z pushed through the real menu-bar
/// key-equivalent path), `import` (the second window scene, its menu item, its
/// grid and its selection commands), `library` (the grid, the g/d module keys
/// and the colour-label keys, all as real keystrokes) and `library2` (the
/// Library module's two views — the grid's scroll position and the loupe — and
/// the Folders panel, the menus and the export sheet). All print PASS/FAIL
/// lines and exit non-zero on failure.
///
/// Repro (c): the whole app, in its own process, painting a stroke with real
/// `NSEvent`s and then telling you — on stdout, in the library and in a
/// screenshot of its own window — where that stroke went.
///
/// It exists because the unit tests can only prove that the canvas's *own* math
/// is self-consistent. This is the only check that runs the real SwiftUI window,
/// the real sidebar layout, the real decode and the real presented
/// drawable, i.e. the thing the user actually reported on.
///
/// Nothing here is reachable without the environment variable, and it writes a
/// development into the real library for whatever RAW it was pointed at.
enum SelfTest {
    enum Mode: String {
        /// Repro (c): a stroke painted with real `NSEvent`s.
        case paint
        /// Repro (d): Cmd-Z / Cmd-Shift-Z pushed through the real menu-bar key
        /// equivalent path, which is where the undo bug actually lived.
        case undo
        /// The import window: the File › Import… item as AppKit sees it, the
        /// second `Window` scene actually opening, thumbnails arriving in the
        /// grid, and the selection commands moving the ring and the checkboxes.
        ///
        /// `GRAYROOM_SELFTEST_IMPORT_DIR` names the folder to scan (default
        /// `testdata`). `GRAYROOM_SELFTEST_IMPORT_RUN=1` additionally presses
        /// Import — which *writes to the library*, so run it with
        /// `CFFIXED_USER_HOME` pointed at a throwaway directory:
        ///
        /// ```
        /// CFFIXED_USER_HOME=$(mktemp -d) GRAYROOM_SELFTEST=import \
        ///     GRAYROOM_SELFTEST_IMPORT_RUN=1 swift run GrayroomApp
        /// ```
        ///
        /// `HOME` alone is not enough: Foundation resolves Application Support
        /// from `CFFIXED_USER_HOME` or the passwd entry, not from `HOME`.
        case importWindow = "import"
        /// The Library module: that the app starts there, that the grid has a
        /// cell per photo, that clicks and arrows move the ring, and that
        /// Lightroom's keys — `8` for green, `6` for red, `d` and `g` for the
        /// two modules — do what they do in Lightroom, pushed in as real
        /// keystrokes through the menu-bar key-equivalent path.
        ///
        /// It imports into the library, so run it against a throwaway home:
        ///
        /// ```
        /// CFFIXED_USER_HOME=$(mktemp -d) GRAYROOM_SELFTEST=library \
        ///     swift run GrayroomApp
        /// ```
        case library
        /// The other half of the Library run, in a process of its own: the
        /// grid's scroll position across a trip through Develop, the loupe,
        /// the Folders panel, the window's chrome, the menus and the export sheet.
        ///
        /// Two processes rather than one because the Library test covers two
        /// unrelated halves — the grid and its previews here, the module's
        /// views and the window's furniture there — and each half then has a
        /// whole run's deadline to itself and can be driven on its own while it
        /// is being worked on. Both import `testdata` into a throwaway library
        /// of their own and are run the same way:
        ///
        /// ```
        /// CFFIXED_USER_HOME=$(mktemp -d) GRAYROOM_SELFTEST=library2 \
        ///     swift run GrayroomApp
        /// ```
        case library2
        /// Photo switching, autosave and preview requests, using synthetic files.
        case loading
    }

    /// Whether this run is one of the two halves of the Library test.
    static var isLibraryRun: Bool { mode == .library || mode == .library2 }

    static var mode: Mode? {
        ProcessInfo.processInfo.environment["GRAYROOM_SELFTEST"].flatMap(Mode.init(rawValue:))
    }

    static var isRequested: Bool { mode != nil }

    static var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["GRAYROOM_SELFTEST_OUT"] ?? "out"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// When the run began — set at launch, so a phase line says how far into
    /// the run it is and not how far into the checks.
    static var startedAt = Date()

    /// Marks a phase of a run, with how long the run has taken so far. The
    /// Library test is split across two processes because it does not fit in
    /// one deadline; these lines are how the split is kept balanced.
    static func phase(_ name: String) {
        log(String(format: "self-test: --- %@ at %.1f s", name, -startedAt.timeIntervalSinceNow))
    }

    /// How long a whole self-test may take before every `wait…` gives up and
    /// lets the checks report what they see. A full-resolution export of a
    /// 100-megapixel frame is seconds on its own, and the library run does the
    /// grid, the previews, the panel and the sheet before it gets there.
    static var deadline = Date().addingTimeInterval(300)

    /// Keeps every window this process opens out of the user's way.
    ///
    /// A self-test drives real windows with real events, and those windows used
    /// to jump in front of whatever the user was doing for the half-minute the
    /// run takes. So: the app is an accessory (set by the delegate, no Dock
    /// tile and no menu bar of its own), it never activates, and every window
    /// it opens — the editor, the Import window, any that come later — is put
    /// one level *below* the desktop icons, where it is still a real, laid-out,
    /// drawn window that `cacheDisplay` can draw off its own view tree, and where nothing about it is on screen.
    ///
    /// `hidesOnDeactivate` stays false so an inactive app keeps its windows
    /// (and therefore its layout, its rows and its click targets) alive.
    static func stayOutOfTheWay() {
        guard isRequested else { return }
        guard windowObserver == nil else { return }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            demote(window)
        }
        for window in NSApp.windows { demote(window) }
    }

    static var windowObserver: Any?

    static let hiddenWindowLevel =
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)

    /// Whether every window this process has is where `stayOutOfTheWay` put
    /// it. A popover or a sheet is a window too, and one that came up above the
    /// desktop would be on the user's screen.
    static func everyWindowIsOutOfTheWay() -> Bool {
        NSApp.windows.allSatisfy { !$0.isVisible || $0.level <= hiddenWindowLevel }
    }

    static func demote(_ window: NSWindow) {
        if window.level != hiddenWindowLevel { window.level = hiddenWindowLevel }
        if window.hidesOnDeactivate { window.hidesOnDeactivate = false }
    }

    /// Makes SwiftUI publish its accessibility tree.
    ///
    /// It builds one only for a process it believes an assistive client is
    /// attached to, and nothing is attached to a self-test: without this a
    /// hosting view answers no accessibility children at all (measured), and a
    /// SwiftUI `Button` — which has no `NSControl` behind it since macOS 26 —
    /// is not addressable by anything. `AXEnhancedUserInterface` is the flag
    /// AppKit itself sets on the application when VoiceOver arrives.
    static func enableAccessibility() {
        (NSApp as AnyObject).accessibilitySetValue?(
            true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    static func startIfRequested() {
        guard isRequested else { return }
        enableAccessibility()
        startedAt = Date()
        deadline = startedAt.addingTimeInterval(300)
        if mode == .loading {
            Task { @MainActor in await runLoadingChecks() }
            return
        }
        // The import window does not need a document, so it does not wait for
        // one — pointing this mode at a RAW file just to get past the poll
        // would be a decode the test has no use for.
        if mode == .importWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { runImportWindow() }
            return
        }
        // Same reason: the library test starts from an empty library and no
        // document at all — waiting for a first render would wait forever.
        if isLibraryRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { runLibrary() }
            return
        }
        log("self-test: waiting for the first render")
        poll()
    }

    static func waitForDecode(_ app: AppModel, then body: @escaping (CGSize) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if app.previewSize == .zero, Date() < deadline {
                waitForDecode(app, then: body)
            } else {
                body(app.previewSize)
            }
        }
    }

    /// Copies the source folder into the output directory and drops a
    /// synthetic JPEG in, so the run exercises both decode paths without
    /// writing into `testdata/`.
    ///
    /// `subfolder`, when given, is created and the JPEG goes in *there* instead
    /// of beside the RAWs: that is the second directory the Folders panel has
    /// to show, and the one photo selecting it has to filter the grid down to.
    static func stageSourceWithAJPEG(_ original: URL, subfolder: String? = nil) -> URL {
        let staged = outputDirectory.appendingPathComponent("import-source", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: staged)
        guard (try? FileManager.default.copyItem(at: original, to: staged)) != nil else {
            log("import self-test: could not stage \(original.path); using it directly")
            return original
        }
        var directory = staged
        if let subfolder {
            directory = staged.appendingPathComponent(subfolder, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
        }
        _ = writeSyntheticJPEG(to: directory.appendingPathComponent("standard.jpg"))
        return staged
    }

    /// A 64×48 JPEG with a gradient in it and a capture date on it. `seed`
    /// shifts the pixels so two of these are two different files, and therefore
    /// two photos.
    static func writeSyntheticJPEG(to url: URL, seed: Int = 0,
                                   captured: String = "2021:03:09 08:15:00") -> Bool {
        let width = 64, height = 48
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let value = UInt8((i * 7 + seed) % 256)
            bytes[i * 4] = value
            bytes[i * 4 + 1] = value
            bytes[i * 4 + 2] = UInt8(255 - Int(value))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(
                                      rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            log("self-test: could not build the synthetic JPEG")
            return false
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal as String: captured,
                kCGImagePropertyExifOffsetTimeOriginal as String: "+00:00",
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            log("self-test: could not write the synthetic JPEG")
            return false
        }
        return true
    }

    /// Polls until the import task leaves the activity centre, reporting the
    /// highest `completed` it ever saw — which is how the test knows progress
    /// was reported rather than the task simply appearing and vanishing.
    static func waitForImportToFinish(_ app: AppModel, peak: Int = 0,
                                              then body: @escaping (Int) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let task = app.tasks.tasks.first { $0.title == "Importing photos" }
            let peak = max(peak, task?.completed ?? 0)
            if task != nil, Date() < deadline {
                waitForImportToFinish(app, peak: peak, then: body)
            } else {
                body(peak)
            }
        }
    }

    static func findMenuItem(titled title: String) -> NSMenuItem? {
        guard let main = NSApp.mainMenu else { return nil }
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            submenu.update()
            if let item = submenu.items.first(where: { $0.title == title }) { return item }
        }
        return nil
    }

    static func writeScreenshot(of window: NSWindow, named name: String) {
        let url = outputDirectory.appendingPathComponent(name)
        guard let image = windowImage(window) else {
            log("self-test: could not draw \(name)")
            return
        }
        write(image, to: url)
        log("self-test: wrote \(url.path) (\(image.width)x\(image.height))")
    }

    /// The window's view tree drawn into a bitmap. Needs no screen-recording
    /// permission and works for a window below the desktop, but Metal layers
    /// come out blank — `writeCanvasRender` covers those.
    static func windowImage(_ window: NSWindow) -> CGImage? {
        guard let frame = window.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        return rep.cgImage
    }

    /// The whole of a window's view tree, not just its content.
    ///
    /// The frame view, which is the content view's superview: an `NSToolbar`'s
    /// items are *not* in the content view, they are in the title bar, which is
    /// the content view's sibling under the frame. Open, Import, the module
    /// picker and Export all live there now, so a walk that starts at the
    /// content view finds none of them.
    ///
    /// Window coordinates are the frame view's own, so every rectangle these
    /// searches compare is still in the same space.
    static func searchRoot(of window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        return content.superview ?? content
    }

    /// Whether a view is in the window's title bar rather than in its content —
    /// which is where an `NSToolbar` keeps its items, and therefore the
    /// difference between a control in the window's own bar and one in a row
    /// drawn underneath it.
    static func isInTitleBar(_ view: NSView?) -> Bool {
        guard let view, let content = view.window?.contentView else { return false }
        return !view.isDescendant(of: content)
    }

    /// The transparent `NSView` `ThumbnailGrid` puts behind each cell to catch
    /// clicks. Finding it is how this test can click a *cell* without knowing
    /// anything about the grid's geometry.
    static func cellView(_ identifier: String) -> NSView? {
        func search(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        for window in NSApp.windows where window.isVisible {
            if let root = searchRoot(of: window), let found = search(root) { return found }
        }
        return nil
    }

    /// The same view, waited for.
    ///
    /// `LazyVGrid` materialises a cell on a run-loop turn of SwiftUI's own,
    /// some time after the model behind the grid changed — an import landing, a
    /// folder filtering the grid, a trip through the loupe rebuilding it.
    /// Reading the view straight after the change that asks for it is a race,
    /// and under load the test loses it: measured at one run in three, the grid
    /// had no click target at all when the first check ran. So every check that
    /// needs a cell waits for it here, turning the run loop so the layout it is
    /// waiting for can happen.
    ///
    /// Bounded on its own as well as by the run's deadline, so a cell that
    /// genuinely never appears fails its check instead of eating the rest of
    /// the run.
    static func waitForCell(_ identifier: String, timeout: TimeInterval = 5) -> NSView? {
        let started = Date()
        let limit = min(started.addingTimeInterval(timeout), deadline)
        var turns = 0
        while true {
            if let view = cellView(identifier), view.window != nil {
                if turns > 0 {
                    log(String(format: "self-test: %@ took %.3f s to appear (%d turns)",
                               identifier, -started.timeIntervalSinceNow, turns))
                }
                return view
            }
            guard Date() < limit else { return nil }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            turns += 1
        }
    }

    /// Whether the grid has a click target behind every one of these cells,
    /// waiting for them the way `waitForCell` does.
    static func waitForCells(_ identifiers: [String], timeout: TimeInterval = 5) -> Bool {
        identifiers.allSatisfy { waitForCell($0, timeout: timeout) != nil }
    }

    /// Whether this app can read the file at all — the same probe the importer
    /// uses, so a file that fails here is one the import was always going to
    /// reject.
    static func canDecode(_ url: URL) -> Bool {
        (try? ImageDecoder.probe(url: url)) != nil
    }

    static func cellID(_ id: Int64) -> String { "grid-cell-\(id)" }
    static func cellID(_ url: URL) -> String { "grid-cell-\(url)" }

    /// A real click on a cell, with real modifier flags on the event — the
    /// thing a tap gesture cannot see.
    ///
    /// `fromTopLeft`, when given, aims at a point inside the cell instead of
    /// its centre: that is how the import window's checkbox gets clicked, and
    /// therefore how this test knows the checkbox still takes its own clicks
    /// rather than the click catcher swallowing them.
    ///
    /// `clickCount` is how many clicks to send, not a number to stamp on one
    /// event: a window routes a multi-click event to the view that took the
    /// *previous* mouse-down rather than to the one under the point, so a lone
    /// `clickCount: 2` lands on whatever was clicked last (measured on macOS 26
    /// — a double-click aimed at the first cell opened the cell clicked two
    /// steps earlier). Sending 1, then 2, is what the hardware sends.
    @discardableResult
    static func clickCell(_ identifier: String,
                                  modifiers: NSEvent.ModifierFlags = [],
                                  clickCount: Int = 1,
                                  fromTopLeft: CGPoint? = nil) -> Bool {
        guard let view = waitForCell(identifier), let window = view.window else {
            log("self-test: no click target \(identifier)")
            return false
        }
        let local = fromTopLeft.map { CGPoint(x: view.bounds.minX + $0.x,
                                              y: view.bounds.maxY - $0.y) }
            ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let point = view.convert(local, to: nil)
        for count in 1...max(clickCount, 1) {
            clickCounter += 1
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: clickCounter, clickCount: count, pressure: 1)
                else { return false }
                window.sendEvent(event)
            }
        }
        return true
    }

    static var clickCounter = 0

    static func screenFrame(of view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    // MARK: - Named controls

    /// Every view in this app's windows with a given `identifier`, popovers,
    /// sheets and title bars included — the first two are windows of their own
    /// (the activity centre's list lives in one), and the third is where the
    /// window's own chrome is (see `searchRoot(of:)`).
    static func views(identified identifier: String) -> [NSView] {
        var found: [NSView] = []
        func search(_ view: NSView) {
            if view.identifier?.rawValue == identifier { found.append(view) }
            view.subviews.forEach(search)
        }
        for window in NSApp.windows where window.isVisible {
            if let root = searchRoot(of: window) { search(root) }
        }
        return found
    }

    /// The `ControlProbe` behind a named control — its rectangle *is* the
    /// control's, which is what `control(named:)` turns into the control.
    static func probeView(_ name: String) -> NSView? {
        views(identified: ControlProbe.identifier(name)).first { $0.window != nil }
    }

    /// The real `NSControl` a `.controlProbe(name)` names, when there is one.
    ///
    /// A `Toggle`, a `Picker` and a `Slider` are AppKit controls — an
    /// `NSButton`, an `NSPopUpButton`, an `NSSlider`, an `NSSegmentedControl` —
    /// but they carry no title, no identifier and no accessibility label a test
    /// could match on (measured; see `ControlProbe`). What they do have is a
    /// frame, and the probe sits at exactly that frame. So the control is the
    /// innermost `NSControl` in the same window that the probe's rectangle
    /// contains.
    ///
    /// Driving *that* — a new value plus its action — is what makes those
    /// checks real: a control whose action is not wired to the model fails them,
    /// and so does one that is no longer there.
    ///
    /// A `Button` answers `nil` here: since macOS 26 SwiftUI draws one itself
    /// and puts no `NSControl` behind it (see `AXElement`). Read one through
    /// `axElement(named:)` and press it with `clickProbe(named:)`.
    static func control(named name: String) -> NSControl? {
        guard let probe = probeView(name), let window = probe.window,
              let root = searchRoot(of: window) else {
            log("self-test: no control probe named '\(name)'")
            return nil
        }
        let rect = probe.convert(probe.bounds, to: nil)
        var controls: [NSControl] = []
        func search(_ view: NSView) {
            if let control = view as? NSControl { controls.append(control) }
            view.subviews.forEach(search)
        }
        search(root)
        guard let index = match(rect, among: controls.map { $0.convert($0.bounds, to: nil) })
        else {
            log("self-test: '\(name)' has a probe at \(rect) but no NSControl on it")
            return nil
        }
        return controls[index]
    }

    /// Which of `frames` is the rectangle at `rect` — the geometry both
    /// `control(named:)` and `axElement(named:)` match a probe by.
    ///
    /// Two ways for a rectangle to be a control's, because SwiftUI lays its
    /// controls out three different ways. An `NSButton` is *bigger* than the
    /// SwiftUI box it was given (bezel and focus ring bleed past it) and a
    /// `Picker`'s `NSPopUpButton` is slightly smaller, so for both of those the
    /// two rectangles are nearly the same rectangle. A `Toggle`'s checkbox is a
    /// 16 pt square inside a 150 pt probe that also covers its label, and
    /// nothing about *that* is "nearly the same" — but it is the smallest
    /// control wholly inside the probe, and there is only one.
    ///
    /// So: the nearest rectangle if there is one, otherwise the smallest one the
    /// probe contains. Never simply "the biggest overlap" — the window is full
    /// of large controls that contain any given probe.
    static func match(_ rect: NSRect, among frames: [NSRect]) -> Int? {
        let probeArea = Double(rect.width * rect.height)
        var nearest: (index: Int, score: Double)?
        var contained: (index: Int, area: Double)?
        for (index, frame) in frames.enumerated() {
            let overlap = frame.intersection(rect)
            let intersection = overlap.isNull ? 0 : Double(overlap.width * overlap.height)
            let own = Double(frame.width * frame.height)
            let union = own + probeArea - intersection
            let similarity = union > 0 ? intersection / union : 0
            // A few points of slack for the containment test: a checkbox's
            // `NSButton` is 18 pt where SwiftUI laid out 14, so it hangs 2 pt
            // past the probe on every side and is not, strictly, inside it.
            let grown = frame.intersection(rect.insetBy(dx: -4, dy: -4))
            let insideGrown = own > 0 && !grown.isNull
                ? Double(grown.width * grown.height) / own : 0
            if similarity > 0.4, nearest == nil || similarity > nearest!.score {
                nearest = (index, similarity)
            }
            if insideGrown > 0.9, contained == nil || own < contained!.area {
                contained = (index, own)
            }
        }
        return nearest?.index ?? contained?.index
    }

    /// The accessibility element a `.controlProbe(name)` names — the same
    /// rectangle, read out of the window's accessibility tree instead of its
    /// view tree. See `AXElement` for why the tests need one.
    static func axElement(named name: String) -> AXElement? {
        guard let probe = probeView(name), let window = probe.window else {
            log("self-test: no control probe named '\(name)'")
            return nil
        }
        // Accessibility frames are in screen coordinates, which is what the
        // probe's rectangle has to be turned into to be compared with them.
        let rect = window.convertToScreen(probe.convert(probe.bounds, to: nil))
        var elements: [AXElement] = []
        func search(_ element: AXElement) {
            elements.append(element)
            element.children.forEach(search)
        }
        AXElement(window).children.forEach(search)
        guard let index = match(rect, among: elements.map(\.frame)) else {
            log("self-test: '\(name)' has a probe at \(rect) but no accessibility element "
                + "on it (\(elements.count) in the window)")
            return nil
        }
        return elements[index]
    }

    /// What a named control is, to an accessibility client — `.button`,
    /// `.checkBox`, `.popUpButton`, `.slider`. The assertion that a control is
    /// drawn there at all, and is the kind of control it should be.
    static func role(named name: String) -> NSAccessibility.Role? {
        axElement(named: name)?.role
    }

    /// Whether a named control is live.
    ///
    /// Read off its accessibility node, not an `NSControl`: since macOS 26 a
    /// SwiftUI `Button` has no `NSControl` at all, and its node is the only
    /// thing left that answers for `.disabled(_:)`. Nodes report enablement for
    /// the controls that *are* still `NSControl`s too, so every named control
    /// is read the same way.
    static func isEnabled(named name: String) -> Bool? {
        axElement(named: name)?.isEnabled
    }

    /// Presses a named control.
    ///
    /// Two ways, because a named control is an `NSControl` or it is not. When
    /// it is — a `Toggle`'s checkbox — the honest press is target/action: it
    /// does not depend on which window happens to be key, which this process
    /// cannot reliably arrange (AppKit hands the click that activates a window
    /// to the window, not to the control under it — measured, one run in
    /// three). A SwiftUI `Button` is not an `NSControl`; it is SwiftUI's own
    /// drawing and its own gesture, and the only thing that presses it is a
    /// mouse event. So: the control if there is one, a real click at the
    /// probe's rectangle if there is not.
    ///
    /// Either way a dead control refuses the press, so "pressed X" never passes
    /// on a button the model has disabled.
    @discardableResult
    static func clickControl(named name: String) -> Bool {
        guard isEnabled(named: name) != false else {
            log("self-test: the button named '\(name)' is disabled")
            return false
        }
        if let control = control(named: name) as? NSButton {
            let before = control.state
            control.performClick(nil)
            log("self-test: pressed '\(name)' (\(type(of: control)), "
                + "state \(before.rawValue) -> \(control.state.rawValue), "
                + "action=\(control.action.map(String.init(describing:)) ?? "nil") "
                + "target=\(control.target.map { String(describing: type(of: $0)) } ?? "nil"))")
            return true
        }
        return clickProbe(named: name)
    }

    /// What a named checkbox is drawing right now — `.on`, `.off` or `.mixed`.
    /// The half of a SwiftUI checkbox's wiring a test can read.
    static func checkboxState(named name: String) -> NSControl.StateValue? {
        (control(named: name) as? NSButton)?.state
    }

    /// A real mouse click in the middle of a named control's rectangle — what
    /// presses a SwiftUI-drawn button, which has no target and no action.
    ///
    /// The `ControlProbe` itself is invisible to hit testing, so the click
    /// lands on whatever SwiftUI drew on top of it.
    @discardableResult
    static func clickProbe(named name: String) -> Bool {
        guard let probe = probeView(name), let window = probe.window else {
            log("self-test: nothing named '\(name)' to click")
            return false
        }
        let point = probe.convert(CGPoint(x: probe.bounds.midX, y: probe.bounds.midY), to: nil)
        clickCounter += 1
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: clickCounter, clickCount: 1, pressure: 1)
            else { return false }
            window.sendEvent(event)
        }
        let hit = searchRoot(of: window)?.hitTest(point)
        log("self-test: clicked '\(name)' at \(point) in '\(window.title)' "
            + "(key=\(window.isKeyWindow), hit "
            + (hit.map { String(describing: type(of: $0)) } ?? "nothing") + ")")
        return true
    }

    /// Drags a named slider to a fraction of its travel — what a drag ends
    /// with.
    ///
    /// A fraction and not a value: SwiftUI hands its `Slider` an `NSSlider`
    /// that runs 0…1 whatever range the binding has (measured — a `96…320`
    /// slider answers `minValue == 0`), so a value in the model's own units
    /// would be clamped to one end.
    @discardableResult
    static func setSliderFraction(named name: String, to fraction: Double) -> Bool {
        guard let slider = control(named: name) as? NSSlider else {
            log("self-test: no slider named '\(name)'")
            return false
        }
        let value = slider.minValue + fraction * (slider.maxValue - slider.minValue)
        slider.doubleValue = value
        slider.sendAction(slider.action, to: slider.target)
        log("self-test: moved '\(name)' to \(slider.doubleValue) "
            + "(range \(slider.minValue)…\(slider.maxValue))")
        return true
    }

    /// Picks an item out of a named `NSPopUpButton` by its title.
    @discardableResult
    static func selectPopUpItem(named name: String, titled title: String) -> Bool {
        guard let popUp = control(named: name) as? NSPopUpButton else {
            log("self-test: no pop-up named '\(name)'")
            return false
        }
        guard popUp.itemTitles.contains(title) else {
            log("self-test: '\(name)' has no item '\(title)' (\(popUp.itemTitles))")
            return false
        }
        popUp.selectItem(withTitle: title)
        // The *item's* action, not the pop-up's: SwiftUI puts the binding's
        // write on each `NSMenuItem` and leaves the button's own action nil
        // (measured — `popUp.sendAction` changed the button's title and nothing
        // else).
        if let item = popUp.selectedItem, let action = item.action,
           NSApp.sendAction(action, to: item.target, from: item) {
            return true
        }
        popUp.sendAction(popUp.action, to: popUp.target)
        return true
    }

    /// Where a named control is on screen, or `nil` when it is not drawn at
    /// all — which is the assertion for anything that appears and disappears.
    static func controlFrame(named name: String) -> NSRect? {
        probeView(name).flatMap(screenFrame(of:))
    }

    /// Every accessibility element in a window, with the facts a check reads
    /// off one: role, label, enablement and frame. The counterpart of
    /// `dumpViews` for the controls that are no longer views.
    static func dumpAX(in window: NSWindow) {
        func walk(_ element: AXElement, indent: String) {
            log("self-test: ax \(indent)\(type(of: element.object)) "
                + "role=\(element.role?.rawValue ?? "-") label='\(element.label ?? "")' "
                + "enabled=\(element.isEnabled) frame=\(element.frame)")
            element.children.forEach { walk($0, indent: indent + "  ") }
        }
        log("self-test: ax tree of '\(window.title)'")
        walk(AXElement(window), indent: "")
    }

    /// Every view in a window, with the facts that decide whether a test can
    /// find it: its class, its accessibility and its frame. The counterpart of
    /// `dumpMenus` for the parts of the UI that are views.
    ///
    /// The window's toolbar — the one `NavigationSplitView` installs for its
    /// sidebar button — is listed separately as well: its items are in the
    /// title bar rather than the content view.
    static func dumpViews(in window: NSWindow) {
        guard let root = searchRoot(of: window) else { return }
        func walk(_ view: NSView, indent: String) {
            log("self-test:   \(indent)\(type(of: view)) "
                + "id='\(view.identifier?.rawValue ?? "")' "
                + "role=\(view.accessibilityRole()?.rawValue ?? "-") "
                + "label='\(view.accessibilityLabel() ?? "")' "
                + "value='\((view.accessibilityValue() as? String) ?? "")' "
                + "frame=\(view.frame)")
            view.subviews.forEach { walk($0, indent: indent + "  ") }
        }
        log("self-test: views in '\(window.title)'")
        func name(_ view: NSView?) -> String {
            view.map { String(describing: type(of: $0)) } ?? "nil"
        }
        log("self-test: contentView=\(name(window.contentView)) "
            + "superview=\(name(window.contentView?.superview)) "
            + "toolbar=\(window.toolbar.map { "\($0.items.count) items" } ?? "nil")")
        for item in window.toolbar?.items ?? [] {
            log("self-test:   toolbar item '\(item.itemIdentifier.rawValue)' "
                + "label='\(item.label)' view=\(name(item.view))")
        }
        walk(root, indent: "")
    }

    static func waitForScan(_ model: ImportModel, then body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if Date() < deadline, model.isScanning || model.totalCount == 0 {
                waitForScan(model, then: body)
            } else {
                body()
            }
        }
    }

    /// Every menu item AppKit has, submenus included — the colour labels live
    /// one level down, in Photo › Set Color Label.
    static func findMenuItemDeep(titled title: String) -> NSMenuItem? {
        func search(_ menu: NSMenu) -> NSMenuItem? {
            menu.update()
            for item in menu.items {
                if item.title == title { return item }
                if let submenu = item.submenu, let found = search(submenu) { return found }
            }
            return nil
        }
        guard let main = NSApp.mainMenu else { return nil }
        return search(main)
    }

    /// Which top-level menu an item sits in — "View", "Photo", and so on.
    static func menu(containing item: NSMenuItem?) -> String? {
        guard let item, let main = NSApp.mainMenu else { return nil }
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            func search(_ menu: NSMenu) -> Bool {
                for candidate in menu.items {
                    if candidate === item { return true }
                    if let sub = candidate.submenu, search(sub) { return true }
                }
                return false
            }
            if search(submenu) { return top.title }
        }
        return nil
    }

    /// Every menu item in the bar that matches — how a test asks whether two
    /// items are fighting over one key equivalent.
    static func menuItems(where matches: (NSMenuItem) -> Bool) -> [NSMenuItem] {
        guard let main = NSApp.mainMenu else { return [] }
        var found: [NSMenuItem] = []
        func search(_ menu: NSMenu) {
            menu.update()
            for item in menu.items {
                if matches(item) { found.append(item) }
                if let sub = item.submenu { search(sub) }
            }
        }
        search(main)
        return found
    }


    // MARK: - Waiting

    static func poll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let model = AppModel.shared
            guard Date() < deadline else { fail("timed out waiting for the first render") }
            guard let canvas = findCanvas(), canvas.window != nil,
                  model.previewSize != .zero, canvas.imageTexture != nil,
                  !model.isDecoding, !model.isRendering else {
                poll()
                return
            }
            switch mode {
            case .paint, nil: run(canvas: canvas, model: model)
            case .undo: runUndo(canvas: canvas, model: model)
            case .importWindow, .library, .library2, .loading: break
            }
        }
    }

    /// The **develop** view's canvas. The loupe draws the same class of view, so
    /// it is told apart by the identifier `AppModel.makeLoupeCanvas` puts on
    /// it — "the develop canvas is not in the window" has to stay a question a
    /// test can ask while the loupe is up.
    static func findCanvas() -> CanvasNSView? {
        canvases().first { $0.identifier?.rawValue != AppModel.loupeCanvasIdentifier }
    }

    /// The Library loupe's canvas.
    static func findLoupeCanvas() -> CanvasNSView? {
        canvases().first { $0.identifier?.rawValue == AppModel.loupeCanvasIdentifier }
    }

    static func canvases() -> [CanvasNSView] {
        var found: [CanvasNSView] = []
        func search(_ view: NSView) {
            if let c = view as? CanvasNSView { found.append(c) }
            view.subviews.forEach(search)
        }
        for window in NSApp.windows {
            if let root = window.contentView { search(root) }
        }
        return found
    }

    static func settle(_ model: AppModel, then body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if model.isRendering || model.isDecoding, Date() < deadline {
                settle(model, then: body)
            } else {
                body()
            }
        }
    }

    /// Runs each step with a settle (render/decode quiescence) in between.
    static func runSteps(_ steps: [() -> Void], model: AppModel,
                                 then done: @escaping () -> Void) {
        guard let first = steps.first else { done(); return }
        first()
        settle(model) { runSteps(Array(steps.dropFirst()), model: model, then: done) }
    }

    /// Pushes a real keystroke into the app.
    ///
    /// The event is built as a **`CGEvent`** and converted with
    /// `NSEvent(cgEvent:)`, not with `NSEvent.keyEvent(with:…)`. That is not
    /// incidental: AppKit's menu key-equivalent matching consults the event's
    /// underlying CGEvent (key code plus the current keyboard layout), so a
    /// hand-rolled `NSEvent` with the "right" character strings matches
    /// differently from a real keystroke — measured here: a hand-rolled
    /// Cmd-Shift-Z matched nothing at all, while the CGEvent-shaped one matches
    /// Redo. A self-test that used the hand-rolled form would report a bug the
    /// user does not have, or miss one they do.
    ///
    /// `NSApp.sendEvent` is the same entry point the window server uses, so this
    /// goes through menu key-equivalent matching, item validation and all.
    /// `viaQueue` puts the keystroke in the application's event queue instead of
    /// dispatching it straight away. That is the only way to exercise a key
    /// `KeyRouter` claims — its local monitor runs when the app *dequeues* an
    /// event and never sees one handed to `NSApp.sendEvent` — and it is what a
    /// real keystroke does. The caller must let the run loop turn afterwards,
    /// which every step here does.
    static func sendKey(_ characters: String, modifiers: NSEvent.ModifierFlags,
                                window: NSWindow, virtualKey: CGKeyCode = 6 /* Z */,
                                viaQueue: Bool = false) {
        log("self-test: sending key \(describe(modifiers))\(characters)")
        guard let source = CGEventSource(stateID: .privateState) else {
            fail("could not make a CGEventSource")
        }
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        for isDown in [true, false] {
            guard let cg = CGEvent(keyboardEventSource: source, virtualKey: virtualKey,
                                   keyDown: isDown) else { fail("could not make a CGEvent") }
            cg.flags = flags
            guard let event = NSEvent(cgEvent: cg) else { fail("CGEvent -> NSEvent failed") }
            if isDown {
                log("undo self-test:   event characters='\(event.characters ?? "")' "
                    + "ignoringModifiers='\(event.charactersIgnoringModifiers ?? "")' "
                    + "flags=\(event.modifierFlags.rawValue)")
            }
            if viaQueue {
                NSApp.postEvent(event, atStart: false)
            } else {
                NSApp.sendEvent(event)
            }
        }
    }

    /// One half of a keystroke, for a key that means something while it is
    /// *held* — `\`, whose press and release `KeyRouter` sees separately.
    /// Through the queue, like every other key that router claims.
    static func sendKeyHalf(virtualKey: CGKeyCode, down: Bool) {
        log("self-test: sending key \(down ? "down" : "up") \(virtualKey)")
        guard let source = CGEventSource(stateID: .privateState),
              let cg = CGEvent(keyboardEventSource: source, virtualKey: virtualKey,
                               keyDown: down),
              let event = NSEvent(cgEvent: cg) else { fail("could not make a CGEvent") }
        NSApp.postEvent(event, atStart: false)
    }

    static func describe(_ modifiers: NSEvent.ModifierFlags) -> String {
        (modifiers.contains(.command) ? "Cmd-" : "") + (modifiers.contains(.shift) ? "Shift-" : "")
            + (modifiers.contains(.option) ? "Opt-" : "")
    }

    /// Every menu item AppKit currently has, with the facts that decide whether
    /// a key equivalent fires: enablement, autoenabling, target and action.
    static func dumpMenus() {
        guard let main = NSApp.mainMenu else {
            log("undo self-test: NSApp.mainMenu is nil")
            return
        }
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            submenu.update()
            log("undo self-test: menu '\(top.title)' autoenables=\(submenu.autoenablesItems)")
            for item in submenu.items where !item.isSeparatorItem {
                log("undo self-test:   item '\(item.title)' enabled=\(item.isEnabled) "
                    + "key='\(item.keyEquivalent)' mask=\(item.keyEquivalentModifierMask.rawValue) "
                    + "action=\(item.action.map(String.init(describing:)) ?? "nil") "
                    + "target=\(item.target.map { String(describing: type(of: $0)) } ?? "nil")")
            }
        }
    }

    static func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                         1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// A trace line from elsewhere in the app, printed only while a self-test is
    /// running so the normal app stays silent.
    static func note(_ message: String) {
        guard isRequested else { return }
        log("trace: " + message)
    }

    static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    static func fail(_ message: String) -> Never {
        log("self-test FAILED: \(message)")
        exit(2)
    }
}

/// One accessibility element, as the self-test reads it.
///
/// # Why the tests read controls this way
///
/// Since macOS 26 a SwiftUI `Button` is not backed by an `NSButton`. Under the
/// probe's rectangle there is a `_FocusRingView`, a `KeyViewProxy` and nothing
/// else — no `NSControl`, so no `isEnabled`, no `keyEquivalent` and nothing to
/// `performClick` (measured; a `Toggle`, a `Picker` and a `Slider` still get
/// their `NSButton`, `NSPopUpButton` and `NSSlider`).
///
/// What SwiftUI does still publish for a button is an accessibility node,
/// carrying its role, its label and its live enablement — so that is what the
/// checks read. It publishes them only once `SelfTest.enableAccessibility()`
/// has run.
///
/// Key equivalents are *not* in there, and are no longer observable at all:
/// `.keyboardShortcut(.defaultAction)` and `.cancelAction` leave the sheet's
/// window answering `nil` for `defaultButtonCell`, for
/// `accessibilityDefaultButton()` and for `accessibilityCancelButton()`, and
/// the node has no key attribute (measured). Those checks press the key
/// instead, which is the stronger assertion anyway.
struct AXElement {
    let object: AnyObject

    init(_ object: AnyObject) { self.object = object }

    var role: NSAccessibility.Role? { (object.accessibilityRole?()) ?? nil }
    var label: String? { (object.accessibilityLabel?()) ?? nil }
    var isEnabled: Bool { object.isAccessibilityEnabled?() ?? false }
    /// In screen coordinates, which is what `SelfTest.axElement(named:)` turns
    /// a probe's rectangle into to match it.
    var frame: NSRect { object.accessibilityFrame?() ?? .zero }
    var children: [AXElement] {
        (((object.accessibilityChildren?()) ?? nil) ?? []).map { AXElement($0 as AnyObject) }
    }
}

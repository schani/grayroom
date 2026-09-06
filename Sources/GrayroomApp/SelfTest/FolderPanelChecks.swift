import AppKit
import GrayroomUI

extension SelfTest {
    static let folderSubfolderName = "Subfolder"
    static var stagedSource: URL?

    static func runFolderChecks(app: AppModel, window: NSWindow,
                                check: @escaping (Bool, String) -> Void,
                                failures: @escaping () -> [String]) {
        phase("dates")
        check(app.folders.totalCount == app.catalog.count, "date tree counts every photo")
        check(app.folders.missingCount == app.catalog.photos.filter { $0.capturedAt == nil }.count,
              "Unknown Date counts undated photos")

        guard let year = app.folders.roots.first,
              let month = year.children.first,
              let day = month.children.first else {
            check(false, "a captured-at year/month/day hierarchy")
            runWindowChecks(app: app, window: window, check: check, failures: failures)
            return
        }
        app.expandedFolders.insert(year.id)
        app.expandedFolders.insert(month.id)
        waitForStablePanel(window) {
            check(sidebarRow(FolderSidebar.rowIdentifier(year.id), in: window) != nil,
                  "year row is visible")
            check(sidebarRow(FolderSidebar.rowIdentifier(month.id), in: window) != nil,
                  "month row is visible")
            check(sidebarRow(FolderSidebar.rowIdentifier(day.id), in: window) != nil,
                  "day row is visible")
            check(clickRow(FolderSidebar.rowIdentifier(day.id), in: window),
                  "day row accepts a click")
            settle(app) {
                check(app.folderSelection == .folder(path: day.id), "day click selects its date")
                check(app.visiblePhotoIDs == app.folders.photoIDs(for: .folder(path: day.id)),
                      "day click filters the grid")
                check(sidebarRow(FolderSidebar.rowIdentifier("missing"), in: window)?.label
                        == "Unknown Date", "undated row is named Unknown Date")
                try? FileManager.default.createDirectory(at: outputDirectory,
                                                         withIntermediateDirectories: true)
                writeScreenshot(of: window, named: "selftest-library.png")
                waitForPreviews(app) {
                    runWindowChecks(app: app, window: window, check: check, failures: failures)
                }
            }
        }
    }

    static func waitForStablePanel(_ window: NSWindow, then body: @escaping () -> Void) {
        let before = sidebarRows(in: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let after = sidebarRows(in: window)
            let same = before.count == after.count
                && !zip(before, after).contains { $0.identifier != $1.identifier
                    || $0.frame != $1.frame }
            if Date() < deadline, !same {
                waitForStablePanel(window, then: body)
            } else {
                body()
            }
        }
    }

    struct AccessibleRow {
        let identifier: String
        let label: String
        let value: String
        let help: String
        let tooltip: String?
        let frame: NSRect
    }

    static func sidebarRows(in window: NSWindow) -> [AccessibleRow] {
        guard let root = window.contentView else { return [] }
        var views: [NSView] = []
        func search(_ view: NSView) {
            if view is SidebarRowTargetView, view.identifier != nil { views.append(view) }
            view.subviews.forEach(search)
        }
        search(root)
        return views.compactMap { view -> AccessibleRow? in
            guard let identifier = view.identifier?.rawValue,
                  identifier.hasPrefix("folder-row-"),
                  let frame = screenFrame(of: view), frame.height > 0 else { return nil }
            return AccessibleRow(identifier: identifier,
                                 label: view.accessibilityLabel() ?? "",
                                 value: (view.accessibilityValue() as? String) ?? "",
                                 help: view.accessibilityHelp() ?? "",
                                 tooltip: view.toolTip, frame: frame)
        }.sorted { $0.frame.maxY > $1.frame.maxY }
    }

    static func sidebarRow(_ identifier: String, in window: NSWindow) -> AccessibleRow? {
        sidebarRows(in: window).first { $0.identifier == identifier }
    }

    @discardableResult
    static func clickRow(_ identifier: String, in window: NSWindow) -> Bool {
        guard let row = sidebarRow(identifier, in: window) else { return false }
        let point = window.convertPoint(fromScreen: CGPoint(x: row.frame.midX, y: row.frame.midY))
        clickCounter += 1
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: clickCounter, clickCount: 1, pressure: 1)
            else { return false }
            window.sendEvent(event)
        }
        return true
    }

    static func sidebarWidth(in window: NSWindow) -> Double {
        guard let scroll = sidebarTable(in: window)?.enclosingScrollView,
              !scroll.isHiddenOrHasHiddenAncestor else { return 0 }
        return Double(scroll.convert(scroll.bounds, to: nil).width)
    }

    static func sidebarTable(in window: NSWindow) -> NSTableView? {
        func search(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        return window.contentView.flatMap(search)
    }
}

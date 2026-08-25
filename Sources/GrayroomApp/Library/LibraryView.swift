import AppKit
import Combine
import CoreGraphics
import GrayroomLibrary
import GrayroomUI
import SwiftUI

/// Lightroom's Library module: the Folders panel on the left, the grid — every
/// photo in the selected source, at a size the slider sets, with the colour
/// labels visible at a glance — on the right. On `e` the module's other view,
/// the loupe, takes the detail column and the panel collapses out of its way.
///
/// The develop sidebar is not here, because nothing in it applies to a
/// selection of photos. The grid is `ThumbnailGrid`, shared with the import
/// window; what is here is the cell. The count and the size slider are in the
/// window's one status bar (`RootView`), so the grid runs straight down to it
/// instead of standing on a strip of its own. The keyboard is not here either:
/// it is routed at the window level by `KeyRouter`, so the arrows keep working
/// after a click on the toolbar, the size slider or the Folders panel.
struct LibraryView: View {
    @Bindable var model: AppModel

    var body: some View {
        // The panel's visibility is the model's `isSidebarShowing`, which is the
        // user's preference *and* the view mode: the loupe never shows the
        // panel, and it does so without writing to the preference, so there is
        // nothing to restore when `g` comes back and no way for the two to
        // disagree. The setter is refused in the loupe for the same reason —
        // the standard title-bar sidebar button is still in the bar there.
        NavigationSplitView(columnVisibility: Binding(
            get: { model.isFolderSidebarShowing ? .all : .detailOnly },
            set: { visibility in
                // The Library stays in the window while Develop is frontmost
                // (`RootView`), and so does the split view's own title-bar
                // button. Pressing it there would flip a preference with
                // nothing on screen to show for it.
                guard model.mode == .library, model.libraryViewMode == .grid else { return }
                model.isFolderSidebarVisible = visibility != .detailOnly
            }
        )) {
            FolderSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 420)
        } detail: {
            // Lightroom's G/E: the loupe fills the module's content area, and
            // in the loupe that is the whole window.
            //
            // The grid is hidden underneath it rather than taken out, for the
            // same reason Develop does not take the whole Library out (see
            // `RootView`): the grid is an `NSScrollView`, and one that is
            // rebuilt starts at the top, so `g` painted a frame of grid-at-zero
            // before the scroll-into-view could land. Kept mounted, the scroll
            // view survives the trip and there is nothing to put back.
            GeometryReader { geometry in
                ZStack {
                    grid
                        // Held at the width the grid had while it was showing,
                        // for as long as this column is wider than that. The
                        // loupe takes the Folders panel off the window, which
                        // widens the column by the panel's whole width — and a
                        // grid that reflowed into it would fit another column,
                        // shorten its own content and have its scroll offset
                        // *clamped* to the shorter one (measured: 3 columns and
                        // 1440 pt of content became 4 and 1083, and 300 pt of
                        // scroll became 264 — permanently, because nothing puts
                        // a clamped offset back).
                        //
                        // The condition is the column's own width and not the
                        // view mode on purpose. AppKit gives the column its
                        // width back a layout pass *after* the model says the
                        // loupe is gone, so a pin keyed on the mode is lifted
                        // one pass too early — which is exactly when the
                        // reflow, and the clamp, happened.
                        .frame(width: pinnedWidth(inColumnOf: geometry.size.width),
                               alignment: .leading)
                        .opacity(model.libraryViewMode == .grid ? 1 : 0)
                        .allowsHitTesting(model.libraryViewMode == .grid)
                        .accessibilityHidden(model.libraryViewMode != .grid)
                    if model.libraryViewMode == .loupe {
                        LoupeView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: geometry.size.width, initial: true) { _, width in
                    // Only a column that is *not* wider than the grid's own
                    // width is a settled one — see above. A column that is
                    // legitimately wider (the user hid the panel, or the window
                    // grew) says so by clearing the record first.
                    if model.libraryGridWidth <= 0 || width <= model.libraryGridWidth + 1 {
                        model.libraryGridWidth = width
                    }
                }
            }
            // The two things that widen this column for real. Both clear the
            // record, so the next layout pass measures the grid afresh instead
            // of holding it at a width that no longer means anything.
            .onChange(of: model.isFolderSidebarVisible) { model.libraryGridWidth = 0 }
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didResizeNotification)) { _ in
                model.libraryGridWidth = 0
            }
        }
        // `.balanced` and not the default: the grid is not a detail *view* of
        // the panel, it is the module, and it should not push the panel off the
        // window when it wants room.
        //
        // The split view brings the standard sidebar button in the window's
        // title bar with it, which is what shows and hides the panel with the
        // mouse; ⌥⌘S is the same command from the keyboard (`KeyRouter`), and
        // View › Show/Hide Folders is where both are discoverable.
        .navigationSplitViewStyle(.balanced)
    }

    /// The width to hold the grid at inside a column of `columnWidth`, or
    /// `nil` to let it fill that column — which is what it does whenever the
    /// column is the width the grid last had.
    private func pinnedWidth(inColumnOf columnWidth: Double) -> CGFloat? {
        let own = model.libraryGridWidth
        guard own > 0, columnWidth > own + 1 else { return nil }
        return CGFloat(own)
    }

    private var grid: some View {
        ThumbnailGrid(
            items: model.visiblePhotos,
            thumbnailSize: model.libraryThumbnailSize,
            columns: $model.libraryColumns,
            scrollTarget: $model.libraryScrollTarget,
            onClick: { model.libraryClick($0.id, modifiers: $1) },
            // Lightroom's double-click: into the loupe, not Develop (`d` is
            // the only way there from the grid).
            onOpen: { model.libraryClick($0.id, modifiers: []); model.showLoupe() },
            help: { $0.firstLocation ?? "\($0.originalName) — no file on disk" },
            // Read, not kept: this view is never taken out of the window, so
            // the scroll view holds its own position (see `RootView`) and
            // nothing here ever puts one back. What the model carries is the
            // reading, which is how the self-test can say the position never
            // moved.
            onScroll: { model.libraryGridScroll = $0 },
            // Lightroom's drag: the selected photos' originals, as files, into
            // Finder or whatever else takes them.
            dragFiles: { model.draggedFiles(for: $0) },
            dragSelection: model.highlightedPhotoIDs,
            cell: { photo in
                LibraryCell(photo: photo,
                            size: model.libraryThumbnailSize,
                            isHighlighted: model.isHighlighted(photo.id),
                            previews: model.previews)
            }
        )
        .overlay {
            if model.catalog.isEmpty {
                VStack(spacing: 8) {
                    Text("The library is empty").font(.title3)
                    Text("Add photos with File › Import… (⇧⌘I)")
                        .foregroundStyle(.secondary)
                }
            } else if model.visiblePhotoIDs.isEmpty {
                Text(model.folderSelection == .missing
                     ? "No photos are missing their files"
                     : "No photos in this folder")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One frame: its picture, its name, and its colour label as a tint behind both.
///
/// The label is drawn Lightroom's way — the cell's *background* takes the
/// colour, at an opacity low enough to read the filename over — rather than as
/// a dot in a corner. That is what makes a labelled selection legible across a
/// screenful of frames at 120 pt.
struct LibraryCell: View {
    let photo: CatalogPhoto
    let size: Double
    let isHighlighted: Bool
    let previews: PreviewBuilder

    @State private var thumbnail: CGImage?
    @State private var isVisible = true

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if previews.isMissing(photo) {
                    // The library remembers this photo; its file does not
                    // answer. Saying so in the cell is the whole reason the
                    // catalog carries `firstLocation`.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: max(size * 0.18, 14)))
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if photo.developmentCount > 0 {
                    Image(systemName: "slider.horizontal.below.rectangle")
                        .font(.system(size: 9))
                        .padding(3)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .padding(3)
                        .help("\(photo.developmentCount) development(s)")
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isHighlighted ? Color.accentColor : .clear, lineWidth: 3)
            }
            Text(photo.originalName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(LibraryCell.tint(photo.color)))
        // Nothing in this cell is clickable, and SwiftUI's own hit-testing
        // would otherwise claim the click before it reached the grid's
        // `ClickCatcher` underneath. See `ThumbnailGrid`.
        .allowsHitTesting(false)
        .onAppear {
            isVisible = true
            request()
        }
        .onDisappear { isVisible = false }
        .onChange(of: photo.id) {
            thumbnail = nil
            request()
        }
        // The photo was developed while the grid was up (or while it was not):
        // what is on screen is a picture of the edit before this one.
        .onChange(of: photo.developmentFingerprint) {
            request()
        }
    }

    private func request() {
        if let cached = previews.cached(photo) {
            thumbnail = cached
            return
        }
        // The cell has been scrolled off by the time the worker gets to it:
        // that read is not worth doing, and this is how it says so.
        previews.image(for: photo, isStillNeeded: { isVisible }) { image in
            if let image { thumbnail = image }
        }
    }

    /// Lightroom's five, at an opacity that tints the cell without drowning the
    /// filename.
    static func tint(_ color: ColorLabel) -> Color {
        switch color {
        case .unlabeled: return .clear
        case .red: return Color.red.opacity(0.35)
        case .yellow: return Color.yellow.opacity(0.35)
        case .green: return Color.green.opacity(0.35)
        case .blue: return Color.blue.opacity(0.35)
        case .purple: return Color.purple.opacity(0.35)
        }
    }

    /// The same five at full strength — the develop view's status dot.
    static func swatch(_ color: ColorLabel) -> Color {
        switch color {
        case .unlabeled: return .clear
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}

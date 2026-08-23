import AppKit
import CoreGraphics
import GrayroomLibrary
import GrayroomUI
import SwiftUI

/// Lightroom's Library module, grid view: every photo in the catalog, at a size
/// the slider sets, with the colour labels visible at a glance.
///
/// The grid is the whole window in this mode — no develop sidebar, because
/// nothing in it applies to a selection of photos. The structure is
/// `ThumbnailGrid`, shared with the import window; what is here is the cell and
/// the bottom bar. The keyboard is not here either: it is routed at the window
/// level by `KeyRouter`, so the arrows keep working after a click on the
/// toolbar or the size slider.
struct LibraryView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ThumbnailGrid(
                items: model.catalog.photos,
                thumbnailSize: model.libraryThumbnailSize,
                columns: $model.libraryColumns,
                scrollTarget: $model.libraryScrollTarget,
                onClick: { model.libraryClick($0.id, modifiers: $1) },
                onOpen: { model.openPhoto(id: $0.id) },
                help: { $0.firstLocation ?? "\($0.originalName) — no file on disk" },
                cell: { photo in
                    LibraryCell(photo: photo,
                                size: model.libraryThumbnailSize,
                                isHighlighted: model.isHighlighted(photo.id),
                                cache: model.thumbnails)
                }
            )
            .overlay {
                if model.catalog.isEmpty {
                    VStack(spacing: 8) {
                        Text("The library is empty").font(.title3)
                        Text("Add photos with File › Import… (⇧⌘I)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            bottomBar
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text(model.libraryCountLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            Spacer(minLength: 0)
            Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(.secondary)
            Slider(value: $model.libraryThumbnailSize,
                   in: ImportModel.minimumThumbnailSize...ImportModel.maximumThumbnailSize)
                .frame(width: 140)
            Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
    let cache: ThumbnailCache

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
                } else if cache.isMissing(photo) {
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
    }

    private func request() {
        if let cached = cache.cached(photo.id) {
            thumbnail = cached
            return
        }
        // The cell has been scrolled off by the time the worker gets to it:
        // that read is not worth doing, and this is how it says so.
        cache.thumbnail(for: photo, isStillNeeded: { isVisible }) { image in
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

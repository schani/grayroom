import AppKit
import GrayroomUI
import SwiftUI

/// Lightroom's import window, "Add" mode only: a grid of everything found under
/// a folder, with per-file checkboxes and the bulk commands that make ticking a
/// card's worth of frames bearable.
///
/// Nothing is copied or moved — the files stay where they are and the library
/// records their paths.
///
/// The grid itself is `ThumbnailGrid`, shared with the library; the keyboard
/// (arrows, P, U, space, +/-, Esc) is routed at the window level by
/// `KeyRouter`, so it keeps working after a click on the sort picker or the
/// size slider.
struct ImportWindow: View {
    @Bindable var model: ImportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            grid
            Divider()
            bottomBar
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("Source")
                .font(.headline)
            Text(model.sourceURL?.path ?? "No folder chosen")
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(model.sourceURL == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Include subfolders", isOn: $model.includeSubfolders)
                .controlProbe("import-include-subfolders")
            Button("Choose…") { model.chooseSource() }
                .controlProbe("import-choose")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Grid

    private var grid: some View {
        ThumbnailGrid(
            items: model.visibleItems,
            thumbnailSize: model.thumbnailSize,
            columns: $model.columns,
            scrollTarget: .constant(nil),
            onClick: { model.click($0.url, modifiers: $1) },
            help: { $0.alreadyImported ? "Already in library" : $0.filename },
            cell: { item in
                ImportCell(item: item,
                           size: model.thumbnailSize,
                           isHighlighted: model.isHighlighted(item.url),
                           onToggle: { model.toggleCheckbox(item.url) })
            }
        )
        .overlay {
            if model.visibleItems.isEmpty, !model.isScanning {
                Text(model.sourceURL == nil
                     ? "Choose a folder to add photos from"
                     : "No RAW files found here")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        // `.fixedSize()` throughout, and the slider as the only flexible item:
        // without it SwiftUI compresses a crowded bar by truncating button
        // titles ("Unch…") and wrapping the toggle's label onto three lines,
        // which is a worse answer than a slightly narrower slider.
        HStack(spacing: 10) {
            Button("Check All") { model.checkAll() }.fixedSize()
                .controlProbe("import-check-all")
            Button("Uncheck All") { model.uncheckAll() }.fixedSize()
                .controlProbe("import-uncheck-all")
            Toggle("Hide already imported", isOn: $model.hideImported).fixedSize()
                .controlProbe("import-hide-imported")
            Picker("Sort", selection: $model.sort) {
                ForEach(ImportSortOrder.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .controlProbe("import-sort")
            Slider(value: $model.thumbnailSize,
                   in: ImportModel.minimumThumbnailSize...ImportModel.maximumThumbnailSize)
                .frame(minWidth: 60, maxWidth: 120)
                .controlProbe("import-thumbnail-size")
            Spacer(minLength: 0)
            // The scan is a task like any other, so the window shows the same
            // indicator the main window does rather than a second private
            // progress mechanism.
            ActivityIndicator(tasks: model.tasks, width: 170)
            Text("\(model.checkedCount) of \(model.totalCount) checked")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
                .fixedSize()
                .controlProbe("import-cancel")
            Button("Import") {
                model.runImport()
                close()
            }
            .keyboardShortcut(.defaultAction)
            // Fine here — this is a button, not a menu command. The commands
            // builder runs once at launch, which is why `.disabled` is banned
            // there; a view's body re-evaluates whenever `checkedCount` moves.
            .disabled(model.checkedCount == 0)
            .fixedSize()
            .controlProbe("import-run")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func close() {
        model.stopScanning()
        dismiss()
    }
}

/// One frame: the picture, its checkbox and its name.
private struct ImportCell: View {
    let item: ImportItem
    let size: Double
    let isHighlighted: Bool
    let onToggle: () -> Void

    var body: some View {
        // The checkbox is the one thing in this cell that takes its own click;
        // everything else stands aside so the grid's `ClickCatcher` underneath
        // gets it (see `ThumbnailGrid`). Hence the two layers rather than one
        // `.overlay`: the checkbox has to sit *outside* the inert part.
        ZStack(alignment: .topLeading) {
            picture
            Toggle("", isOn: Binding(get: { item.checked }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(4)
        }
    }

    private var picture: some View {
        VStack(spacing: 4) {
            ZStack {
                // The placeholder is the cell: a frame whose picture has not
                // arrived yet holds its square rather than reflowing the grid
                // under the user when it does.
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                if let thumbnail = item.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isHighlighted ? Color.accentColor : .clear, lineWidth: 3)
            }
            Text(item.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size)
        }
        // Greyed rather than hidden: seeing that the card's first half is
        // already in the library is the whole point of scanning it again. A
        // `.pending` cell draws normally — the library's answer costs a full
        // hash of the file, and dimming everything until it lands would make
        // the whole grid look disabled for the length of a card read.
        .opacity(item.alreadyImported ? 0.4 : 1)
        .allowsHitTesting(false)
    }
}

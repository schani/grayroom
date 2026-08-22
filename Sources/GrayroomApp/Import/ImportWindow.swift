import AppKit
import GrayroomUI
import SwiftUI

/// Lightroom's import window, "Add" mode only: a grid of everything found under
/// a folder, with per-file checkboxes and the bulk commands that make ticking a
/// card's worth of frames bearable.
///
/// Nothing is copied or moved — the files stay where they are and the library
/// records their paths.
struct ImportWindow: View {
    @Bindable var model: ImportModel
    @Environment(\.dismiss) private var dismiss

    /// The grid's current column count. `LazyVGrid(.adaptive)` decides it from
    /// the available width and never says what it decided, so it is recomputed
    /// here with the same arithmetic — the arrow keys need it to know what "one
    /// row down" means.
    @State private var columns = 1
    @FocusState private var gridFocused: Bool

    private static let spacing: Double = 12
    private static let padding: Double = 12

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            grid
            Divider()
            bottomBar
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { gridFocused = true }
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
            Button("Choose…") { model.chooseSource() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Grid

    private var grid: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: model.thumbnailSize),
                                       spacing: ImportWindow.spacing)],
                    spacing: ImportWindow.spacing
                ) {
                    ForEach(model.visibleItems) { item in
                        ImportCell(item: item,
                                   size: model.thumbnailSize,
                                   isHighlighted: model.isHighlighted(item.url),
                                   onClick: { model.click(item.url, modifiers: $0) },
                                   onToggle: { model.toggleCheckbox(item.url) })
                    }
                }
                .padding(ImportWindow.padding)
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                columns = ImportWindow.columnCount(width: width, itemWidth: model.thumbnailSize)
            }
            .onChange(of: model.thumbnailSize) { _, size in
                columns = ImportWindow.columnCount(width: geometry.size.width, itemWidth: size)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if model.visibleItems.isEmpty, !model.isScanning {
                Text(model.sourceURL == nil
                     ? "Choose a folder to add photos from"
                     : "No RAW files found here")
                    .foregroundStyle(.secondary)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onKeyPress(action: handle)
        .onTapGesture { gridFocused = true }
    }

    /// The same count `LazyVGrid(.adaptive(minimum:))` arrives at: as many
    /// columns of `itemWidth` as fit, separated by `spacing`, inside the
    /// padded width.
    static func columnCount(width: Double, itemWidth: Double) -> Int {
        let usable = width - 2 * padding
        guard usable > 0, itemWidth > 0 else { return 1 }
        return max(1, Int((usable + spacing) / (itemWidth + spacing)))
    }

    // MARK: - Keys

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow: model.moveHighlight(dx: -1, dy: 0, columns: columns)
        case .rightArrow: model.moveHighlight(dx: 1, dy: 0, columns: columns)
        case .upArrow: model.moveHighlight(dx: 0, dy: -1, columns: columns)
        case .downArrow: model.moveHighlight(dx: 0, dy: 1, columns: columns)
        case .space: model.toggleHighlighted()
        case .escape: close()
        default:
            switch press.characters.lowercased() {
            case "p": model.setCheckedForHighlighted(true)
            case "u": model.setCheckedForHighlighted(false)
            case "+", "=": model.stepThumbnailSize(1)
            case "-", "_": model.stepThumbnailSize(-1)
            default: return .ignored
            }
        }
        return .handled
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        // `.fixedSize()` throughout, and the slider as the only flexible item:
        // without it SwiftUI compresses a crowded bar by truncating button
        // titles ("Unch…") and wrapping the toggle's label onto three lines,
        // which is a worse answer than a slightly narrower slider.
        HStack(spacing: 10) {
            Button("Check All") { model.checkAll() }.fixedSize()
            Button("Uncheck All") { model.uncheckAll() }.fixedSize()
            Toggle("Hide already imported", isOn: $model.hideImported).fixedSize()
            Picker("Sort", selection: $model.sort) {
                ForEach(ImportSortOrder.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Slider(value: $model.thumbnailSize,
                   in: ImportModel.minimumThumbnailSize...ImportModel.maximumThumbnailSize)
                .frame(minWidth: 60, maxWidth: 120)
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
    let onClick: (ImportClickModifiers) -> Void
    let onToggle: () -> Void

    var body: some View {
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
            // An overlay, not a third `ZStack` child: the stack's alignment has
            // to stay `.center` for the fitted thumbnail, and the checkbox has
            // to sit in the corner.
            .overlay(alignment: .topLeading) {
                Toggle("", isOn: Binding(get: { item.checked }, set: { _ in onToggle() }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .padding(4)
            }
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
        .help(item.alreadyImported ? "Already in library" : item.filename)
        .contentShape(Rectangle())
        // `onTapGesture` does not report modifiers and `TapGesture().modifiers`
        // does not compose with a plain tap, so the hardware state is read at
        // the moment of the click instead.
        .onTapGesture { onClick(ImportClickModifiers(NSEvent.modifierFlags)) }
    }
}

extension ImportClickModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: ImportClickModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}

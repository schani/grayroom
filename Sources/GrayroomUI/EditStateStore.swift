import CoreGraphics
import Foundation
import GrayroomCore
import Observation

/// The GUI's copy of the `EditState`, plus the two things a value-type edit
/// model needs around it: gesture-granular undo and a dirty flag for the sidecar
/// autosave.
///
/// It deliberately knows nothing about SwiftUI, Metal or AppKit — the app target
/// binds to it and the test target drives it headlessly.
///
/// # Gesture granularity
///
/// A slider drag emits hundreds of changes and must produce **one** undo step.
/// So mutation comes in two flavours:
///
/// * `update { }` — a live change. Bumps `revision`, fires `onChange`, no undo.
/// * `beginGesture()` / `endGesture(named:)` — brackets a drag; the snapshot
///   taken at the start is registered on the undo stack at the end, and only if
///   something actually changed.
/// * `perform(_:_:)` — both at once, for discrete actions (add mask, toggle).
@Observable
public final class EditStateStore {
    public private(set) var edit: EditState

    /// Bumped on every mutation. Views observe it; the autosave debouncer keys
    /// off it so it never has to diff the whole state.
    public private(set) var revision: Int = 0

    /// `true` between a mutation and the sidecar write that follows it.
    public private(set) var isDirty: Bool = false

    /// Which mask the mask panel is editing (and the brush paints into).
    public var selectedMaskID: UUID?

    /// The brush the *next* stroke will use. Tool state, not edit state: it is
    /// not undoable and is not written to the sidecar (each stroke carries its
    /// own copy, which is what makes it re-editable).
    public var brush = BrushParams()

    /// As-shot white balance from the decode probe, shown when the edit's
    /// temp/tint are `nil`.
    public var asShotTemperature: Double = 5500
    public var asShotTint: Double = 0

    /// Called after every mutation with the cost of the change.
    @ObservationIgnored public var onChange: ((RenderInvalidation) -> Void)?

    @ObservationIgnored public let undoManager = UndoManager()
    @ObservationIgnored private var gestureSnapshot: EditState?

    public init(edit: EditState = EditState()) {
        self.edit = edit
        // The store already knows exactly where a gesture ends, so it groups
        // explicitly rather than letting the run loop decide. That also makes
        // undo behave identically in a headless test, where there is no event
        // loop to close an automatic group.
        undoManager.groupsByEvent = false
    }

    // MARK: - Mutation

    /// A live, un-undoable change (slider drag, stroke in progress).
    public func update(_ body: (inout EditState) -> Void) {
        let old = edit
        var next = edit
        body(&next)
        guard next != old else { return }
        edit = next
        didChange(RenderInvalidation.between(old, next))
    }

    /// Snapshot the state so `endGesture` has something to register.
    public func beginGesture() {
        if gestureSnapshot == nil { gestureSnapshot = edit }
    }

    /// Close a gesture, registering one undo step if anything changed.
    public func endGesture(named name: String) {
        guard let snapshot = gestureSnapshot else { return }
        gestureSnapshot = nil
        guard snapshot != edit else { return }
        registerUndo(restoring: snapshot, named: name)
    }

    /// A discrete, immediately undoable action.
    public func perform(_ name: String, _ body: (inout EditState) -> Void) {
        beginGesture()
        update(body)
        endGesture(named: name)
    }

    /// Wholesale replacement (opening a file, loading a sidecar, undo/redo).
    ///
    /// `name == nil` means "this state came *from* disk": the undo stack is
    /// cleared rather than extended, and the dirty flag stays clear so that
    /// merely opening an image does not rewrite its sidecar.
    public func replace(_ new: EditState, named name: String?) {
        let old = edit
        if let name {
            guard old != new else { return }
            registerUndo(restoring: old, named: name)
            edit = new
            didChange(RenderInvalidation.between(old, new))
        } else {
            undoManager.removeAllActions()
            gestureSnapshot = nil
            edit = new
            didChange(RenderInvalidation.between(old, new), dirty: false)
        }
    }

    private func registerUndo(restoring snapshot: EditState, named name: String) {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { store in
            let current = store.edit
            store.edit = snapshot
            store.didChange(RenderInvalidation.between(current, snapshot))
            // Registering from inside an undo makes this the redo step.
            store.registerUndo(restoring: current, named: name)
        }
        undoManager.setActionName(name)
    }

    private func didChange(_ invalidation: RenderInvalidation, dirty: Bool = true) {
        revision &+= 1
        isDirty = dirty
        onChange?(invalidation)
    }

    public var canUndo: Bool { undoManager.canUndo }
    public var canRedo: Bool { undoManager.canRedo }
    public func undo() { undoManager.undo() }
    public func redo() { undoManager.redo() }

    /// The autosave calls this once the sidecar is on disk.
    public func markSaved() { isDirty = false }

    // MARK: - White balance

    /// The value the temperature slider should show: the edit's, or the as-shot
    /// value when the edit says "as shot" (`nil`).
    public var effectiveTemperature: Double { edit.whiteBalance.temperature ?? asShotTemperature }
    public var effectiveTint: Double { edit.whiteBalance.tint ?? asShotTint }
    public var isAsShotWhiteBalance: Bool {
        edit.whiteBalance.temperature == nil && edit.whiteBalance.tint == nil
    }

    /// Back to as-shot. Both fields go `nil` together: a half-set white balance
    /// would make the sidecar ambiguous about what the decoder was told.
    public func resetWhiteBalanceToAsShot() {
        perform("As Shot White Balance") {
            $0.whiteBalance.temperature = nil
            $0.whiteBalance.tint = nil
        }
    }

    // MARK: - Masks

    public var selectedMaskIndex: Int? {
        guard let id = selectedMaskID else { return nil }
        return edit.masks.firstIndex { $0.id == id }
    }

    public var selectedMask: Mask? {
        guard let i = selectedMaskIndex else { return nil }
        return edit.masks[i]
    }

    /// Appends a mask with a non-colliding default name and selects it.
    @discardableResult
    public func addMask() -> UUID {
        let mask = Mask(name: EditStateStore.nextMaskName(existing: edit.masks.map(\.name)),
                        adjustments: MaskAdjustments(exposure: 0))
        perform("Add Mask") { $0.masks.append(mask) }
        selectedMaskID = mask.id
        return mask.id
    }

    public func deleteMask(id: UUID) {
        guard let i = edit.masks.firstIndex(where: { $0.id == id }) else { return }
        perform("Delete Mask") { $0.masks.remove(at: i) }
        if selectedMaskID == id {
            selectedMaskID = edit.masks.indices.contains(i) ? edit.masks[i].id : edit.masks.last?.id
        }
    }

    public func setMaskEnabled(id: UUID, _ enabled: Bool) {
        guard let i = edit.masks.firstIndex(where: { $0.id == id }) else { return }
        perform(enabled ? "Enable Mask" : "Disable Mask") { $0.masks[i].enabled = enabled }
    }

    /// `Mask 1`, `Mask 2`, … skipping names already taken.
    public static func nextMaskName(existing: [String]) -> String {
        var n = 1
        while existing.contains("Mask \(n)") { n += 1 }
        return "Mask \(n)"
    }

    // MARK: - Stroke authoring

    /// Starts a stroke on the selected mask. Returns `false` when there is
    /// nothing to paint into.
    @discardableResult
    public func beginStroke(at point: CGPoint, pressure: Double, erase: Bool) -> Bool {
        guard let i = selectedMaskIndex else { return false }
        beginGesture()
        let stroke = Stroke(brush: brush, erase: erase,
                            points: [StrokePoint(x: Double(point.x), y: Double(point.y),
                                                 pressure: BrushSizing.normalizedPressure(pressure))])
        update { $0.masks[i].strokes.append(stroke) }
        return true
    }

    /// Extends the stroke in progress, subject to the minimum spacing.
    public func extendStroke(to point: CGPoint, pressure: Double, imageSize: CGSize) {
        guard let i = selectedMaskIndex,
              let last = edit.masks[i].strokes.last,
              let lastPoint = last.points.last else { return }
        let previous = CGPoint(x: lastPoint.x, y: lastPoint.y)
        guard BrushSizing.shouldAppend(point: point, after: previous,
                                       size: last.brush.size, imageSize: imageSize) else { return }
        update {
            $0.masks[i].strokes[$0.masks[i].strokes.count - 1].points.append(
                StrokePoint(x: Double(point.x), y: Double(point.y),
                            pressure: BrushSizing.normalizedPressure(pressure)))
        }
    }

    /// Ends the stroke: one undo step. A single-point stroke (a dab) is kept —
    /// that is a legitimate way to paint.
    public func endStroke() {
        endGesture(named: "Paint Mask")
    }
}

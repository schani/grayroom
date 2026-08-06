import Foundation
import GrayroomCore
import Observation
import XCTest
@testable import GrayroomUI

/// Undo availability has to be *observable*, not merely readable.
///
/// SwiftUI only re-evaluates a body when a property it read inside
/// `withObservationTracking` changes. `canUndo` used to be a computed property
/// forwarding to `UndoManager` — an `@ObservationIgnored` stored reference —
/// which registers nothing with Observation, so anything bound to it was frozen
/// at whatever the value was when it was first read (`false`, at launch).
///
/// These tests pin the property down at the Observation level. They are not the
/// whole story of the Cmd-Z bug (the Edit menu had a second, AppKit-level
/// failure — see `UndoMenu.swift`), but they are the half of it that can be
/// proved headlessly.
final class EditStateStoreObservationTests: XCTestCase {
    /// Runs `body`, then reports whether Observation announced a change to
    /// anything `read` touched.
    /// A reference box: `withObservationTracking`'s `onChange` is a
    /// `@Sendable` closure, so it cannot capture a local `var`.
    private final class Flag: @unchecked Sendable { var isSet = false }

    private func observedChange(reading read: @escaping () -> Void,
                                whenPerforming body: () -> Void) -> Bool {
        let fired = Flag()
        withObservationTracking { read() } onChange: { fired.isSet = true }
        body()
        return fired.isSet
    }

    func testCanUndoIsObservable() {
        let store = EditStateStore()
        let fired = observedChange(reading: { _ = store.canUndo }) {
            store.perform("X") { $0.tone.exposure = 1 }
        }
        XCTAssertTrue(fired, "canUndo went false -> true but Observation never announced it, "
                      + "so the Edit menu's .disabled(!canUndo) is never re-evaluated")
    }

    func testCanRedoIsObservable() {
        let store = EditStateStore()
        store.perform("X") { $0.tone.exposure = 1 }
        let fired = observedChange(reading: { _ = store.canRedo }) {
            store.undo()
        }
        XCTAssertTrue(fired, "canRedo went false -> true but Observation never announced it")
    }

    /// The other direction: undoing back to the bottom of the stack has to make
    /// the menu item go grey again.
    func testCanUndoIsObservableWhenItGoesAway() {
        let store = EditStateStore()
        store.perform("X") { $0.tone.exposure = 1 }
        let fired = observedChange(reading: { _ = store.canUndo }) {
            store.undo()
        }
        XCTAssertTrue(fired, "canUndo went true -> false without an Observation change")
    }

    /// Opening a file (`replace(named: nil)`) clears the stack; the menu must
    /// notice that too.
    func testReplaceClearingTheStackIsObservable() {
        let store = EditStateStore()
        store.perform("X") { $0.tone.exposure = 1 }
        let fired = observedChange(reading: { _ = store.canUndo }) {
            store.replace(EditState(), named: nil)
        }
        XCTAssertTrue(fired, "replace(named: nil) cleared the undo stack without announcing it")
    }
}

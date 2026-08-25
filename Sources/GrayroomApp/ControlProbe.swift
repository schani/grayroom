import AppKit
import SwiftUI

/// Gives one SwiftUI control a name AppKit can find it by.
///
/// # Why this is not `.accessibilityIdentifier`
///
/// SwiftUI has one, and in this app it is not enough: nothing SwiftUI writes on
/// a control reaches an `NSView` a test could find. Measured: an
/// `.accessibilityIdentifier("import-check-all")` on the Import window's button
/// reaches **no** `NSView` in that window at all — the backing view answers an
/// empty identifier, an empty title and an empty accessibility label, and its
/// visible text is drawn by a private view that answers nothing either. Since
/// macOS 26 there is no backing view for a `Button` to ask.
///
/// So the same trick the Folders panel's rows and the photo grid's cells
/// already use: a plain `NSView` behind the control, carrying the name. It is
/// the *only* addressable thing about a SwiftUI control from inside the
/// process, and it comes for free — the view draws nothing, takes no clicks
/// (`hitTest` returns `nil`, so the control on top keeps every event) and is
/// hidden from accessibility clients, which read the control itself.
///
/// The probe gives its control's rectangle, and the self-test turns that into
/// the thing sitting in it and drives *that* — so a control whose action is
/// unwired, or gone, fails the test. Which thing depends on the control:
/// `SelfTest.control(named:)` for a `Slider`, a `Picker` or a `Toggle`, which
/// are still an `NSSlider`, an `NSPopUpButton` and an `NSButton`, and
/// `SelfTest.axElement(named:)` for a `Button`, which since macOS 26 is no
/// `NSControl` at all (see `AXElement`).
struct ControlProbe: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> ControlProbeView {
        let view = ControlProbeView()
        view.identifier = NSUserInterfaceItemIdentifier(ControlProbe.identifier(name))
        return view
    }

    func updateNSView(_ nsView: ControlProbeView, context: Context) {
        nsView.identifier = NSUserInterfaceItemIdentifier(ControlProbe.identifier(name))
    }

    static func identifier(_ name: String) -> String { "control-\(name)" }
}

final class ControlProbeView: NSView {
    /// Invisible to the mouse: the control this sits behind must keep every
    /// event, including the ones the self-test synthesizes.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Invisible to VoiceOver too — the control on top is the element.
    override func isAccessibilityElement() -> Bool { false }
}

extension View {
    /// Names this control so AppKit — and therefore the self-test — can find
    /// it. See `ControlProbe`.
    func controlProbe(_ name: String) -> some View {
        background(ControlProbe(name: name))
    }

    /// Puts a real `NSView` behind this view to take its clicks, and names it.
    ///
    /// The same arrangement the Folders panel's rows and the photo grid's cells
    /// have, for the same two reasons: a SwiftUI button does not take a click
    /// that also brings its window forward (so a Grayroom window that is not in
    /// front needs two clicks), and a SwiftUI button in a window the user
    /// cannot see is not addressable at all — it is not even an `NSControl`
    /// once `.buttonStyle(.plain)` is on it, so there is nothing to press and
    /// nothing to read.
    ///
    /// The view this is applied to stops taking clicks, exactly as a grid cell
    /// does, so the target behind it gets them.
    func clickTarget(_ name: String, label: String, value: String = "",
                     tooltip: String? = nil,
                     onClick: @escaping () -> Void) -> some View {
        allowsHitTesting(false)
            .background(ClickCatcher(identifier: ControlProbe.identifier(name),
                                     help: tooltip,
                                     accessibilityLabel: label,
                                     accessibilityValue: value) { _, _ in onClick() })
            .accessibilityHidden(true)
    }
}

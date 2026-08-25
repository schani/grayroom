import Foundation
import GrayroomCore

/// Whether the system has asked the app to stop showing HDR content.
///
/// macOS 26 tells an app when something else on screen needs the panel's
/// brightness (`NSApplicationShouldBeginSuppressingHighDynamicRangeContent-
/// Notification`, and its `...End...` partner). Suppression is a *display*
/// state, not an edit: `hdr` stays exactly as the user set it and the picture
/// comes back the moment the system says it may.
///
/// It takes both halves. Dropping the layer to standard dynamic range on its
/// own would clamp everything above SDR white; rendering the SDR rendition on
/// its own would leave the layer asking for headroom it no longer uses. So the
/// canvas's flag and `displayEdit` move together — see `AppModel`.
///
/// The state is settable directly, which is what lets a test exercise the
/// switch without the notification.
@Observable
public final class HDRSuppression {
    public private(set) var isSuppressed: Bool
    /// Called when the state actually changes, so the canvas and the render
    /// loop can follow it.
    public var onChange: ((Bool) -> Void)?

    public init(isSuppressed: Bool = false) {
        self.isSuppressed = isSuppressed
    }

    public func set(_ suppressed: Bool) {
        guard suppressed != isSuppressed else { return }
        isSuppressed = suppressed
        onChange?(suppressed)
    }

    /// The rendition to put on screen for `edit`: the edit itself, or its SDR
    /// half while HDR is suppressed. Below the tone curve's shoulder knee the
    /// two are the same picture; above it the SDR one rolls off to 1.0, which
    /// is the same thing an export does.
    public func displayEdit(_ edit: EditState) -> EditState {
        guard isSuppressed else { return edit }
        var sdr = edit
        sdr.hdr = false
        return sdr
    }
}

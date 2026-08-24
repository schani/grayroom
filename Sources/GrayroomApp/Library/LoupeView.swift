import AppKit
import GrayroomCanvas
import GrayroomUI
import SwiftUI

/// Lightroom's Library loupe: one photo, as developed, filling the module's
/// whole content area.
///
/// The Folders panel is **not** beside it — Lightroom's `E` gives the photo the
/// window — but this is still a *view* of the Library module and not a module of
/// its own, which is why the toolbar's picker stays on Library, `g` comes
/// straight back to the grid, and the panel comes back exactly as it was left.
///
/// # What it shows
///
/// The real canvas: the same `CanvasNSView` the develop view uses, so the loupe
/// pans, zooms and reaches the display's headroom the way Develop does, and so
/// that stepping between the two views costs nothing when it is the same photo.
/// What is *on* the canvas is `AppModel.loadLoupeImage`'s business: the pipeline
/// over development #1 for a developed photo, the camera's own embedded preview
/// for one that has never been developed, and the grid's 512 px preview standing
/// in until whichever of those lands.
///
/// # Zoom
///
/// Develop's, exactly: `0` fits, `1` is 100 %, a double-click toggles between
/// them at the point clicked, pinch and ⌘-scroll zoom at the cursor, a plain
/// scroll pans, and the percentage is in the status bar.
struct LoupeView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            // The canvas paints its own backdrop — the same one, in the same
            // linear space — so a photo sits against the same neutral in both
            // views.
            if let message = model.loupeMessage {
                Rectangle()
                    .fill(Color(.sRGB,
                                red: CanvasColors.backdropSRGB.0,
                                green: CanvasColors.backdropSRGB.1,
                                blue: CanvasColors.backdropSRGB.2))
                    .ignoresSafeArea()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .controlProbe("loupe-missing")
            } else {
                LoupeCanvasView(model: model)
                    .controlProbe("loupe-image")
                if model.loupeTexture == nil {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .controlProbe("loupe")
    }
}

/// SwiftUI wrapper around the loupe's `MTKView`.
///
/// The same arrangement `CanvasView` has for the develop view, and for the same
/// reason: textures and transforms are pushed onto the view imperatively by
/// `AppModel` the moment they exist, so a full-resolution frame never makes a
/// round trip through the SwiftUI update graph to reach the screen.
struct LoupeCanvasView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> CanvasNSView {
        let view = model.makeLoupeCanvas()
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: CanvasNSView, context: Context) {}
}

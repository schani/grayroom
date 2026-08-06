import AppKit
import GrayroomCanvas
import SwiftUI

/// SwiftUI wrapper around the `MTKView` canvas.
///
/// The view is intentionally *not* driven by SwiftUI state: textures and
/// transforms are pushed onto it imperatively by `AppModel` the moment a render
/// finishes, so a 3 MP frame never has to make a round trip through the SwiftUI
/// update graph to reach the screen.
struct CanvasView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> CanvasNSView {
        let view = model.makeCanvas()
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: CanvasNSView, context: Context) {
        nsView.tool = model.tool
        nsView.eraserActive = model.eraserActive
        nsView.brushSize = model.store.brush.size
        nsView.brushFeather = model.store.brush.feather
    }
}

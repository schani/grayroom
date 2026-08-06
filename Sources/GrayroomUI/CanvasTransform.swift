import CoreGraphics
import Foundation

/// The zoom/pan state of the image canvas, and all the coordinate mapping that
/// goes with it.
///
/// # Units
///
/// Everything here is in **device pixels**, not points. The canvas view
/// scales AppKit's point coordinates by `backingScaleFactor` before it talks
/// to this type (NOT via `convertToBacking(_ point:)`, which negates y in a
/// flipped view). The payoff is that `zoom` reads directly as the familiar
/// magnification number: `zoom == 1` is one image pixel per screen pixel, i.e.
/// Lightroom's "1:1" / 100 %.
///
/// # The mapping
///
/// ```
/// view  = (image − center) · zoom + viewSize/2
/// image = (view − viewSize/2) / zoom + center
/// ```
///
/// `center` is the point of the image (in image pixels) that sits under the
/// centre of the view, which makes both zoom-at-cursor and edge clamping easy
/// to state. There is no rotation and no flip: image y runs **down**, and so
/// does the canvas view's (it sets `isFlipped`), so the two agree with the
/// texture's row order and with the mask coordinate convention.
public struct CanvasTransform: Equatable {
    /// Size of the displayed image, in image pixels.
    public var imageSize: CGSize
    /// Size of the canvas, in device pixels.
    public var viewSize: CGSize
    /// Device pixels per image pixel.
    public var zoom: Double
    /// Image-space point (pixels) shown at the centre of the view.
    public var center: CGPoint

    public static let minZoom: Double = 0.02
    public static let maxZoom: Double = 32.0

    public init(imageSize: CGSize, viewSize: CGSize, zoom: Double, center: CGPoint) {
        self.imageSize = imageSize
        self.viewSize = viewSize
        self.zoom = zoom
        self.center = center
    }

    /// A transform that fits the whole image in the view, centred.
    public static func fitting(imageSize: CGSize, viewSize: CGSize) -> CanvasTransform {
        var t = CanvasTransform(imageSize: imageSize, viewSize: viewSize, zoom: 1,
                                center: CGPoint(x: imageSize.width / 2, y: imageSize.height / 2))
        t.zoom = t.fitZoom
        return t
    }

    // MARK: - Zoom levels

    /// The zoom at which the whole image is visible. Never above 1: an image
    /// smaller than the view is shown at 100 %, not blown up.
    public var fitZoom: Double {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return 1 }
        let z = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        return min(Double(z), 1.0)
    }

    /// `true` when the current zoom is (within a pixel-ish tolerance) the fit zoom.
    public var isFit: Bool { abs(zoom - fitZoom) < 1e-4 }

    /// Magnification as a percentage, the number the title bar shows.
    public var zoomPercent: Double { zoom * 100 }

    /// Clamps a zoom request to the allowed range. The fit zoom is always
    /// reachable even for an image so large that fit is below `minZoom`.
    public func clampZoom(_ z: Double) -> Double {
        let lo = min(CanvasTransform.minZoom, fitZoom)
        return min(max(z, lo), CanvasTransform.maxZoom)
    }

    // MARK: - Coordinate mapping

    /// View (device pixels) -> image pixels.
    public func imagePoint(fromView v: CGPoint) -> CGPoint {
        let z = zoom == 0 ? 1 : zoom
        return CGPoint(x: (v.x - viewSize.width / 2) / z + center.x,
                       y: (v.y - viewSize.height / 2) / z + center.y)
    }

    /// Image pixels -> view (device pixels).
    public func viewPoint(fromImage i: CGPoint) -> CGPoint {
        CGPoint(x: (i.x - center.x) * zoom + viewSize.width / 2,
                y: (i.y - center.y) * zoom + viewSize.height / 2)
    }

    /// View -> normalised oriented-image coordinates (`0…1`, y down), which is
    /// the space `StrokePoint` lives in. Values outside `0…1` are legal and are
    /// deliberately not clamped: a stroke may start off-canvas.
    public func normalizedPoint(fromView v: CGPoint) -> CGPoint {
        let p = imagePoint(fromView: v)
        let w = imageSize.width > 0 ? imageSize.width : 1
        let h = imageSize.height > 0 ? imageSize.height : 1
        return CGPoint(x: p.x / w, y: p.y / h)
    }

    /// Normalised oriented-image coordinates -> view (device pixels).
    public func viewPoint(fromNormalized n: CGPoint) -> CGPoint {
        viewPoint(fromImage: CGPoint(x: n.x * imageSize.width, y: n.y * imageSize.height))
    }

    /// `true` when the view point lands inside the image.
    public func containsImagePoint(view v: CGPoint) -> Bool {
        let p = imagePoint(fromView: v)
        return p.x >= 0 && p.y >= 0 && p.x < imageSize.width && p.y < imageSize.height
    }

    // MARK: - Gestures

    /// Zoom, keeping the image point currently under `anchor` under `anchor`.
    public func zoomed(to newZoom: Double, anchorView anchor: CGPoint) -> CanvasTransform {
        var t = self
        let anchorImage = imagePoint(fromView: anchor)
        t.zoom = clampZoom(newZoom)
        // Solve viewPoint(anchorImage) == anchor for the new centre.
        t.center = CGPoint(x: anchorImage.x - (anchor.x - viewSize.width / 2) / t.zoom,
                           y: anchorImage.y - (anchor.y - viewSize.height / 2) / t.zoom)
        return t.clampedToBounds()
    }

    /// Multiply the zoom (scroll wheel, pinch), anchored at a view point.
    public func scaled(by factor: Double, anchorView anchor: CGPoint) -> CanvasTransform {
        zoomed(to: zoom * factor, anchorView: anchor)
    }

    /// Drag the image by a view-space delta (the image follows the cursor).
    public func panned(byViewDelta d: CGSize) -> CanvasTransform {
        var t = self
        let z = zoom == 0 ? 1 : zoom
        t.center = CGPoint(x: center.x - d.width / z, y: center.y - d.height / z)
        return t.clampedToBounds()
    }

    /// Toggle between fit and 100 % (double click). Zooming *in* keeps the
    /// clicked point where it is; zooming out re-centres.
    public func toggledFitAndActualSize(anchorView anchor: CGPoint) -> CanvasTransform {
        if isFit && fitZoom < 1 {
            return zoomed(to: 1, anchorView: anchor)
        }
        return CanvasTransform.fitting(imageSize: imageSize, viewSize: viewSize)
    }

    /// Re-fit after a view resize while trying to keep the framing: fit stays
    /// fit, anything else keeps its zoom and its centre (clamped).
    public func resized(viewSize newSize: CGSize) -> CanvasTransform {
        let wasFit = isFit
        var t = self
        t.viewSize = newSize
        if wasFit {
            t.zoom = t.fitZoom
            t.center = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
            return t
        }
        return t.clampedToBounds()
    }

    // MARK: - Bounds

    /// Keeps the image glued to the view: an axis smaller than the view is
    /// centred on that axis, a larger one may not be dragged past its edge.
    public func clampedToBounds() -> CanvasTransform {
        var t = self
        let z = zoom == 0 ? 1 : zoom
        func clamp(_ c: Double, imageExtent: Double, viewExtent: Double) -> Double {
            let half = viewExtent / 2 / z
            if imageExtent <= 2 * half { return imageExtent / 2 }
            return min(max(c, half), imageExtent - half)
        }
        t.center = CGPoint(
            x: clamp(center.x, imageExtent: imageSize.width, viewExtent: viewSize.width),
            y: clamp(center.y, imageExtent: imageSize.height, viewExtent: viewSize.height))
        return t
    }
}

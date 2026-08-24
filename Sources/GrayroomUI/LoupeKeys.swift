import Foundation

/// What a bare keystroke means in the Library module's loupe.
///
/// The table lives here, away from the window, because "0 zooms to fit in the
/// loupe" is exactly the kind of claim a test should be able to make without an
/// `NSWindow` — and because the loupe and the develop view have to agree about
/// the zoom keys, which is easier to see when the loupe's whole key table is one
/// switch in one place. `KeyRouter` decodes the arrows (they are function keys,
/// not characters) and dispatches everything else through here.
public enum LoupeCommand: Equatable, Sendable {
    /// One photo along the filtered order.
    case step(Int)
    /// `g`, or Esc: back to the grid.
    case grid
    /// `d`: develop the photo on screen.
    case develop
    /// `6`–`9`, as a `ColorLabel` raw value.
    case colorLabel(Int)
    /// `0` — Lightroom's Fit, and the develop view's own key for it.
    case zoomToFit
    /// `1` — 100 %, likewise.
    case zoomToActualSize
    /// The key belongs to the loupe and there is nothing to do: `e` and Return
    /// while the loupe is already up, and the vertical arrows, which walk rows
    /// the loupe does not have.
    case nothing
}

public enum LoupeKeys {
    /// The loupe's answer to one keystroke, `nil` when the key is not the
    /// loupe's and should fall through to whoever else wants it.
    ///
    /// `characters` is `charactersIgnoringModifiers`, lowercased.
    public static func command(for characters: String) -> LoupeCommand? {
        switch characters {
        // Lightroom's way out of any secondary view, twice over.
        case "g", "\u{1b}": return .grid
        case "e", "\r", "\u{3}": return .nothing        // already here
        case "d": return .develop
        case "6": return .colorLabel(1)
        case "7": return .colorLabel(2)
        case "8": return .colorLabel(3)
        case "9": return .colorLabel(4)
        // The loupe zooms exactly as the develop canvas does, so it takes the
        // develop canvas's keys.
        case "0": return .zoomToFit
        case "1": return .zoomToActualSize
        default: return nil
        }
    }

    /// The same for an arrow. Left and right walk the filtered list one photo at
    /// a time; up and down mean nothing here, and are still swallowed so they
    /// cannot fall through to the grid underneath.
    public static func command(forArrow dx: Int, _ dy: Int) -> LoupeCommand {
        dx == 0 ? .nothing : .step(dx)
    }
}

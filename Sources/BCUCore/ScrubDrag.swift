import CoreGraphics

/// A drag along History's track: where it started, and the playhead then.
/// `pointerX` is in the track's own points and `windowX` is the window's
/// left edge on screen. The drag is measured on screen, since a lane more
/// can resize and re-center the panel under a still pointer.
public struct ScrubDrag {
    var startX: CGFloat
    public var startScroll: CGFloat

    public init(pointerX: CGFloat, windowX: CGFloat, scroll: CGFloat) {
        startX = pointerX + windowX
        startScroll = scroll
    }

    /// How far the pointer has gone since the drag started.
    public func distance(pointerX: CGFloat, windowX: CGFloat) -> CGFloat {
        pointerX + windowX - startX
    }

    /// The playhead for the pointer where it is now.
    public func scroll(pointerX: CGFloat, windowX: CGFloat) -> CGFloat {
        startScroll - distance(pointerX: pointerX, windowX: windowX)
    }
}

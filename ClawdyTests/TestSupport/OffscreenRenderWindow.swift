import AppKit

/// Creates a borderless, transparent NSWindow positioned far off-screen so it does not
/// flash in the lower-left corner of the display during test runs. The window is fully
/// functional for pixel-capture rendering — AppKit still composites its content even
/// when the frame lies outside every connected screen.
func makeOffscreenRenderWindow(width: CGFloat, height: CGFloat) -> NSWindow {
    let offscreenRect = NSRect(x: -10000, y: -10000, width: width, height: height)
    let window = NSWindow(
        contentRect: offscreenRect,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    return window
}

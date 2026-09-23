import Cocoa

public final class FloatingBarPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Float at the status bar level across all spaces
        self.level = .statusBar
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
    }

    // Crucial: allow clicks on SwiftUI buttons while never stealing keyboard focus from active windows
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

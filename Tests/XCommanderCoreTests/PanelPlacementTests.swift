import Testing
@testable import XCommanderCore

/// Where the panel lands, including when centring on Xcode would put it off the screen.
@Suite("Panel placement")
struct PanelPlacementTests {

    private let screen = PaneRect(x: 0, y: 0, width: 1920, height: 1080)

    private func place(width: Double, on target: PaneRect) -> PaneRect {
        PanelPlacement.frame(width: width, height: 380, topInset: 120,
                             centredOn: target, within: screen)
    }

    @Test("centred on Xcode when there is room")
    func centred() {
        let xcode = PaneRect(x: 300, y: 100, width: 1200, height: 900)
        let panel = place(width: 1340, on: xcode)
        #expect(panel.midX == xcode.midX)
        #expect(panel.maxY == xcode.maxY - 120)
    }

    @Test("a window near the left edge does not push the panel off the screen")
    func clampsLeft() {
        // Xcode narrowed and dragged left: centring a 1340pt panel on it wants x = -370.
        let xcode = PaneRect(x: 0, y: 100, width: 600, height: 900)
        let panel = place(width: 1340, on: xcode)
        #expect(panel.minX >= screen.minX)
        #expect(panel.minX == PanelPlacement.screenInset)
    }

    @Test("a window near the right edge does not push the panel off either")
    func clampsRight() {
        let xcode = PaneRect(x: 1320, y: 100, width: 600, height: 900)
        let panel = place(width: 1340, on: xcode)
        #expect(panel.maxX <= screen.maxX)
        #expect(panel.maxX == screen.maxX - PanelPlacement.screenInset)
    }

    @Test("a panel wider than the screen is centred rather than shoved against an edge")
    func widerThanScreen() {
        let narrow = PaneRect(x: 0, y: 0, width: 800, height: 600)
        let panel = PanelPlacement.frame(width: 1340, height: 380, topInset: 120,
                                         centredOn: PaneRect(x: 0, y: 0, width: 700, height: 500),
                                         within: narrow)
        #expect(panel.midX == narrow.midX)
    }

    @Test("a window near the top does not push the panel above the screen")
    func clampsVertically() {
        // Xcode tall and flush to the top: maxY - 380 - 120 still has to fit.
        let xcode = PaneRect(x: 300, y: 900, width: 1200, height: 300)
        let panel = place(width: 1340, on: xcode)
        #expect(panel.maxY <= screen.maxY)
    }

    @Test("the panel keeps the size it was given, whatever the clamping")
    func sizeIsPreserved() {
        // The panel must not resize under the cursor, so placement never changes its size.
        for width in [720.0, 1340.0, 3000.0] {
            let panel = place(width: width, on: PaneRect(x: 0, y: 0, width: 400, height: 400))
            #expect(panel.width == width)
            #expect(panel.height == 380)
        }
    }
}

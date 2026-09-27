import CoreGraphics
import HUDKit

/// Where the panel parks. MacHUD passes its loadout slot's edge and peek with
/// `panel mode parked edge= peek=` (HUDKit 0.2); they are remembered, so a later `parked`
/// without them (the menu, a hotkey, a bare `panel mode parked`) parks in the same place.
/// Until MacHUD names an edge, the panel parks at the screen edge nearest its rest frame.
public struct ParkingSpot: Equatable {
    public var edge: HUDEdge?
    public var peek: CGFloat

    public init(edge: HUDEdge? = nil, peek: CGFloat) {
        self.edge = edge
        self.peek = peek
    }

    /// Takes the edge and peek `options` name, keeping the rest. Returns whether anything changed.
    @discardableResult
    public mutating func update(with options: HUDPanelModeOptions) -> Bool {
        let before = self
        if let edge = options.edge { self.edge = edge }
        if let peek = options.peek, peek.isFinite { self.peek = max(0, peek) }
        return self != before
    }

    /// The remembered edge, else the edge of `screen` nearest `rest`.
    public func edge(for rest: CGRect, in screen: CGRect) -> HUDEdge {
        edge ?? HUDParking.nearestEdge(for: rest, in: screen)
    }

    /// Where a panel resting at `rest` sits while parked on `screen`.
    public func offScreenFrame(for rest: CGRect, in screen: CGRect) -> CGRect {
        HUDParking.offScreenFrame(for: rest, edge: edge(for: rest, in: screen), peek: peek, in: screen)
    }

    /// `offScreenFrame` against the screen `rest` is on.
    @MainActor
    public func offScreenFrame(for rest: CGRect) -> CGRect {
        offScreenFrame(for: rest, in: HUDParking.screenFrame(for: rest))
    }
}

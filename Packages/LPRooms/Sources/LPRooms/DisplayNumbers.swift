import Foundation

public struct DisplayRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }
}

/// A display with the number room pings use: #1 is the primary, the rest go left→right, then top→bottom.
public struct NumberedDisplay: Equatable, Sendable {
    public let number: Int
    public let id: UInt32
    /// In global points, origin at the primary display's top-left, y down (the event tap's coordinate space).
    public let bounds: DisplayRect
    public let primary: Bool
}

public enum DisplayNumbers {
    public static func number(_ displays: [(id: UInt32, bounds: DisplayRect)], primaryId: UInt32) -> [NumberedDisplay] {
        let rest = displays.filter { $0.id != primaryId }.sorted { a, b in
            a.bounds.x != b.bounds.x ? a.bounds.x < b.bounds.x : a.bounds.y < b.bounds.y
        }
        let primary = displays.filter { $0.id == primaryId }
        return (primary + rest).enumerated().map { i, d in
            NumberedDisplay(number: i + 1, id: d.id, bounds: d.bounds, primary: d.id == primaryId)
        }
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    /// A point local to a display (points from its top-left) → its display number and position as a fraction of that display.
    public static func toShared(_ list: [NumberedDisplay], displayId: UInt32, x: Double, y: Double) -> (d: Int, x: Double, y: Double)? {
        guard let d = list.first(where: { $0.id == displayId }), d.bounds.width > 0, d.bounds.height > 0 else { return nil }
        return (d.number, clamp01(x / d.bounds.width), clamp01(y / d.bounds.height))
    }

    /// Where a room ping for display `d` lands here: that display, or the primary when this machine has no #d.
    public static func resolveTarget(_ list: [NumberedDisplay], d: Int) -> NumberedDisplay? {
        list.first { $0.number == d } ?? list.first
    }
}

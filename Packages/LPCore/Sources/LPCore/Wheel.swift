import Foundation

public enum WheelKind: String, Codable, Sendable {
    case ping, emote
}

/// The wheel's dimensions in points, and which slice a pointer offset falls on.
public enum WheelMetrics {
    public static let sliceCount = 8
    /// The hub: releasing inside it sends nothing.
    public static let hubRadius: Double = 86
    public static let ringRadius: Double = 188
    /// How far the four straight-up/down/left/right slices fade outwards past the ring.
    public static let reachRadius: Double = 288
    public static let badgeRadius: Double = 137
    public static let badgeSide: Double = 48

    /// The slice under a pointer that is `dx`, `dy` away from the wheel's centre (y grows downwards).
    /// Slice 0 points up and the numbers go clockwise; each slice is 45° wide, centred on its direction.
    /// Nil inside the hub.
    public static func slice(dx: Double, dy: Double) -> Int? {
        guard (dx * dx + dy * dy).squareRoot() >= hubRadius else { return nil }
        // atan2(dx, -dy) is the clockwise angle from "up"; shift by half a slice so each slice straddles its direction.
        var turns = atan2(dx, -dy) / (2 * .pi) + 0.5 / Double(sliceCount)
        turns -= turns.rounded(.down)
        return min(sliceCount - 1, Int(turns * Double(sliceCount)))
    }
}

/// What a wheel holds: eight slices and the item that trigger + click sends. The editor's model.
public struct WheelArrangement: Equatable, Sendable {
    public var slices: [String]
    public var quick: String

    public init(slices: [String], quick: String) {
        self.slices = slices
        self.quick = quick
    }

    /// Where an item being moved comes from.
    public enum Origin: Equatable, Sendable {
        case library(String)
        case slice(Int)
        case quick
    }

    /// Where it is put.
    public enum Destination: Equatable, Sendable {
        case slice(Int)
        case quick
    }

    public func item(at origin: Origin) -> String {
        switch origin {
        case .library(let id): return id
        case .slice(let i): return slices[i]
        case .quick: return quick
        }
    }

    /// The arrangement after moving an item, or nil when the move changes nothing.
    /// An item never ends up on two slices: putting one that is already on the wheel onto another slice makes the two
    /// slices trade places. The quick item is independent of the slices, so it may also be on the wheel.
    public func moving(_ origin: Origin, to destination: Destination) -> WheelArrangement? {
        let id = item(at: origin)
        var next = self
        switch destination {
        case .quick:
            next.quick = id
        case .slice(let target):
            if let current = slices.firstIndex(of: id) {
                next.slices.swapAt(current, target)
            } else {
                next.slices[target] = id
            }
        }
        return next == self ? nil : next
    }
}

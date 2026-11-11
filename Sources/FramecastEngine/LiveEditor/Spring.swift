import Foundation

/// A spring stepped at a fixed 1/120 s, so a move looks the same whatever the frame rate or timer jitter, and keeps
/// its speed when the target changes (a retarget never jerks). Response is the time to settle in seconds;
/// damping 1 is critical (no overshoot).
public struct Spring: Sendable, Equatable {
    public static let step = 1.0 / 120
    public var value: Double
    public var velocity = 0.0
    public init(_ value: Double) { self.value = value }

    public mutating func step(toward target: Double, response: Double, damping: Double = 1) {
        let r = max(0.05, response)
        let k = pow(2 * .pi / r, 2), c = 4 * .pi * damping / r
        let a = -k * (value - target) - c * velocity
        velocity += a * Self.step
        value += velocity * Self.step
    }

    /// Where it would be `dt` (less than one step) after the last step.
    public func ahead(_ dt: Double) -> Double { value + velocity * dt }
    public var isAtRest: Bool { abs(velocity) < 1e-4 }
}


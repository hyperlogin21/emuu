import Foundation

/// Exponentially weighted moving average with a time constant (irregular sample spacing is fine).
public struct EWMA: Sendable, Hashable {
    /// Time for the weight of an old value to fall to 1/e.
    public let timeConstant: Duration
    public private(set) var value: Double?
    private var lastTime: Duration?

    public init(timeConstant: Duration) {
        self.timeConstant = timeConstant
    }

    @discardableResult
    public mutating func add(_ x: Double, at t: Duration) -> Double {
        guard let v = value, let lt = lastTime else {
            value = x
            lastTime = t
            return x
        }
        let dt = max(0, (t - lt).timeInterval)
        let tau = max(1e-9, timeConstant.timeInterval)
        let alpha = 1 - exp(-dt / tau)
        let nv = v + alpha * (x - v)
        value = nv
        lastTime = t
        return nv
    }

    public mutating func reset() {
        value = nil
        lastTime = nil
    }
}

/// Least-squares line over a bounded, down-sampled window of (time, value) points.
/// Memory is O(capacity) forever: points closer than `minSpacing` to the previous kept point are
/// dropped, and the oldest point is overwritten when full.
public struct TrendWindow: Sendable {
    public struct Point: Sendable, Hashable {
        public var t: Duration
        public var value: Double
    }

    public struct Fit: Sendable, Hashable {
        /// Slope in value units per hour.
        public var slopePerHour: Double
        /// Coefficient of determination (0…1); how linear the trend is.
        public var r2: Double
        /// Time spanned by the points used.
        public var span: Duration
        public var pointCount: Int
    }

    public let minSpacing: Duration
    private(set) var points: RingBuffer<Point>

    public init(capacity: Int, minSpacing: Duration) {
        self.minSpacing = minSpacing
        self.points = RingBuffer(capacity: max(2, capacity))
    }

    public var count: Int { points.count }

    /// Adds a point; returns false if it was dropped by down-sampling.
    @discardableResult
    public mutating func add(_ value: Double, at t: Duration) -> Bool {
        if let last = points.last, t - last.t < minSpacing { return false }
        points.append(Point(t: t, value: value))
        return true
    }

    public mutating func reset() { points.removeAll() }

    /// Linear fit over all retained points (nil with fewer than 3 points or zero time span).
    public func fit() -> Fit? {
        guard points.count >= 3, let first = points.first, let last = points.last else { return nil }
        let t0 = first.t
        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, syy = 0.0
        points.forEach { p in
            let x = (p.t - t0).timeInterval / 3600.0
            let y = p.value
            n += 1; sx += x; sy += y; sxx += x * x; sxy += x * y; syy += y * y
        }
        let denom = n * sxx - sx * sx
        guard denom > 1e-12 else { return nil }
        let slope = (n * sxy - sx * sy) / denom
        let varY = n * syy - sy * sy
        let r2: Double
        if varY <= 1e-12 {
            r2 = 0
        } else {
            let r = (n * sxy - sx * sy) / (denom.squareRoot() * varY.squareRoot())
            r2 = min(1, max(0, r * r))
        }
        return Fit(slopePerHour: slope, r2: r2, span: last.t - first.t, pointCount: Int(n))
    }
}

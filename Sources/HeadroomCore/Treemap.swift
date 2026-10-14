import Foundation

/// Squarified treemap layout (Bruls, Huizing & van Wijk): tiles keep aspect ratios close to
/// square, so even small folders stay readable and clickable.
public enum Treemap {
    public struct Rect: Sendable, Hashable {
        public var x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public var area: Double { width * height }
    }

    /// Lay out `values` (any order) inside `bounds`. Returns one rect per value, same order.
    public static func layout(_ values: [Double], in bounds: Rect) -> [Rect] {
        let total = values.reduce(0, +)
        guard total > 0, bounds.area > 0 else { return values.map { _ in Rect(x: bounds.x, y: bounds.y, width: 0, height: 0) } }
        // Work largest-first, then map back to the caller's order.
        let order = values.indices.sorted { values[$0] > values[$1] }
        let scale = bounds.area / total
        let areas = order.map { max(0, values[$0]) * scale }
        var placed = [Rect](repeating: Rect(x: 0, y: 0, width: 0, height: 0), count: values.count)

        var remaining = bounds
        var row: [Int] = [] // indices into `areas`
        var i = 0
        while i < areas.count {
            let side = min(remaining.width, remaining.height)
            if row.isEmpty || worst(row.map { areas[$0] } + [areas[i]], side: side) <= worst(row.map { areas[$0] }, side: side) {
                row.append(i)
                i += 1
            } else {
                remaining = place(row, areas: areas, in: remaining, order: order, into: &placed)
                row = []
            }
        }
        if !row.isEmpty { _ = place(row, areas: areas, in: remaining, order: order, into: &placed) }
        return placed
    }

    /// The worst aspect ratio in a row laid along a side of length `side`.
    static func worst(_ row: [Double], side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0, let maxA = row.max(), let minA = row.min(), minA > 0 else { return .infinity }
        let s2 = side * side, sum2 = sum * sum
        return max(s2 * maxA / sum2, sum2 / (s2 * minA))
    }

    /// Place a finished row along the shorter side; return the space left.
    static func place(_ row: [Int], areas: [Double], in r: Rect, order: [Int], into placed: inout [Rect]) -> Rect {
        let sum = row.reduce(0) { $0 + areas[$1] }
        if r.width >= r.height {
            // Column on the left.
            let w = r.height > 0 ? sum / r.height : 0
            var y = r.y
            for idx in row {
                let h = w > 0 ? areas[idx] / w : 0
                placed[order[idx]] = Rect(x: r.x, y: y, width: w, height: h)
                y += h
            }
            return Rect(x: r.x + w, y: r.y, width: max(0, r.width - w), height: r.height)
        } else {
            // Row along the top.
            let h = r.width > 0 ? sum / r.width : 0
            var x = r.x
            for idx in row {
                let w = h > 0 ? areas[idx] / h : 0
                placed[order[idx]] = Rect(x: x, y: r.y, width: w, height: h)
                x += w
            }
            return Rect(x: r.x, y: r.y + h, width: r.width, height: max(0, r.height - h))
        }
    }
}

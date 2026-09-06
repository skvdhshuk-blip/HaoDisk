import Foundation
import CoreGraphics

struct MapWeight: Sendable {
    let id: Int
    let value: Double
}

struct MapTile: Identifiable, Sendable {
    let id: Int
    let rect: CGRect
}

/// Squarified treemap. Geometry is independent of views and uses the full measured area.
enum Treemap {
    static func layout(_ input: [MapWeight], in bounds: CGRect) -> [MapTile] {
        let weights = input.filter { $0.value.isFinite && $0.value > 0 }.sorted { $0.value > $1.value }
        let sum = weights.reduce(0) { $0 + $1.value }
        guard sum > 0, sum.isFinite, bounds.width > 0, bounds.height > 0 else { return [] }
        let scale = bounds.width * bounds.height / sum
        let items = weights.map { MapWeight(id: $0.id, value: $0.value * scale) }
        var remaining = bounds
        var output: [MapTile] = []
        var row: [MapWeight] = []

        func worst(_ row: [MapWeight], side: Double) -> Double {
            guard let smallest = row.map(\.value).min(), let largest = row.map(\.value).max(), side > 0 else { return .infinity }
            let total = row.reduce(0) { $0 + $1.value }
            return max(side * side * largest / (total * total), total * total / (side * side * smallest))
        }

        func place(_ row: [MapWeight]) {
            let area = row.reduce(0) { $0 + $1.value }
            if remaining.width >= remaining.height {
                let width = min(remaining.width, area / remaining.height)
                var y = remaining.minY
                for item in row {
                    let height = item.value / width
                    output.append(MapTile(id: item.id, rect: CGRect(x: remaining.minX, y: y, width: width, height: height)))
                    y += height
                }
                remaining.origin.x += width
                remaining.size.width = max(0, remaining.width - width)
            } else {
                let height = min(remaining.height, area / remaining.width)
                var x = remaining.minX
                for item in row {
                    let width = item.value / height
                    output.append(MapTile(id: item.id, rect: CGRect(x: x, y: remaining.minY, width: width, height: height)))
                    x += width
                }
                remaining.origin.y += height
                remaining.size.height = max(0, remaining.height - height)
            }
        }

        for item in items {
            let side = min(remaining.width, remaining.height)
            if row.isEmpty || worst(row + [item], side: side) <= worst(row, side: side) {
                row.append(item)
            } else {
                place(row)
                row = [item]
            }
        }
        if !row.isEmpty { place(row) }
        return output
    }
}

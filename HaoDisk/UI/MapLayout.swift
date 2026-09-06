import AppKit
import SwiftUI

struct MapLayoutKey: Equatable {
    let map: MapKey
    let size: CGSize
}

enum MapLabelMode { case nameAndCapacity, capacity, none }

struct RenderedMapTile: Identifiable {
    let entry: MapEntry
    let rect: CGRect
    let label: MapLabelMode
    let large: Bool
    var id: Int { entry.id }
    var padding: CGFloat { label == .nameAndCapacity ? (large ? 14 : 4) : 2 }
}

private struct MapTextMetrics {
    let capacity: CGSize
    let nameHeight: CGFloat
    init(_ entry: MapEntry, large: Bool) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: large ? 12 : 11, weight: .regular)
        let measured = (entry.capacity as NSString).size(withAttributes: [.font: font])
        capacity = CGSize(width: ceil(measured.width), height: ceil(measured.height))
        let nameFont = NSFont.systemFont(ofSize: large ? 14 : 11, weight: .medium)
        nameHeight = ceil(nameFont.ascender - nameFont.descender + nameFont.leading)
    }
    func mode(in size: CGSize, large: Bool) -> MapLabelMode {
        let padding: CGFloat = large ? 14 : 4
        if capacity.width + padding * 2 <= size.width && nameHeight + 4 + capacity.height + padding * 2 <= size.height {
            return .nameAndCapacity
        }
        if capacity.width + 4 <= size.width && capacity.height + 4 <= size.height { return .capacity }
        return .none
    }
}

@MainActor
final class MapLayoutModel: ObservableObject {
    @Published private(set) var tiles: [RenderedMapTile] = []
    private(set) var layoutCount = 0
    private(set) var measurementCount = 0
    private var key: MapLayoutKey?
    var mapKey: MapKey? { key?.map }
    private var metrics: [Int: (large: MapTextMetrics, small: MapTextMetrics)] = [:]

    func update(_ map: MapPresentation, size: CGSize) {
        let nextKey = MapLayoutKey(map: map.key, size: size)
        guard key != nextKey else { return }
        if key?.map != map.key {
            metrics = Dictionary(uniqueKeysWithValues: map.entries.map {
                ($0.id, (large: MapTextMetrics($0, large: true), small: MapTextMetrics($0, large: false)))
            })
            measurementCount += 1
        }
        key = nextKey
        layoutCount += 1
        let entries = Dictionary(uniqueKeysWithValues: map.entries.map { ($0.id, $0) })
        tiles = Treemap.layout(map.weights, in: CGRect(origin: .zero, size: size)).compactMap { tile in
            guard let entry = entries[tile.id], let metrics = metrics[tile.id] else { return nil }
            let gap = min(3, min(tile.rect.width, tile.rect.height) * 0.2)
            let rect = tile.rect.insetBy(dx: gap / 2, dy: gap / 2)
            let large = rect.width > 145 && rect.height > 90
            let label = (large ? metrics.large : metrics.small).mode(in: rect.size, large: large)
            return RenderedMapTile(entry: entry, rect: rect, label: label, large: large)
        }
    }
}

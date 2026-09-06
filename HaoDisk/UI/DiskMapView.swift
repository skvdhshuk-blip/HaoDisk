import SwiftUI

struct DiskMapView: View {
    @ObservedObject var model: DiskModel
    @StateObject private var layout = MapLayoutModel()
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            if let map = model.presentation?.map {
                let tiles = layout.mapKey == map.key ? layout.tiles : []
                ZStack(alignment: .topLeading) {
                    if map.entries.isEmpty {
                        ContentUnavailableView("没有可绘制的空间", systemImage: "square.dashed", description: Text("文件仍可在目录列表中查看。"))
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    ForEach(tiles) { tile in
                        if tile.id == -1 {
                            Button { openRemaining(map.remainingFirstID) } label: {
                                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08))
                                    .overlay { MapTileLabel(tile: tile) }
                                    .frame(width: tile.rect.width, height: tile.rect.height)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .help(tile.entry.tooltip)
                                .accessibilityLabel("\(tile.entry.accessibilityLabel)，在列表中查看")
                                .offset(x: tile.rect.minX, y: tile.rect.minY)
                        } else {
                            DiskMapTile(tile: tile, version: map.key.version, model: model) { focused = true }
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let tile = tiles.last(where: { $0.id == -1 }), tile.label != .nameAndCapacity {
                        Button { openRemaining(map.remainingFirstID) } label: {
                            Label("\(tile.entry.name) · \(tile.entry.capacity)", systemImage: "list.bullet")
                                .font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 6)
                        }.buttonStyle(.plain).background(.regularMaterial, in: Capsule()).padding(8)
                            .help("在列表中查看其余项目")
                    }
                }
                .onChange(of: MapLayoutKey(map: map.key, size: geometry.size), initial: true) { _, _ in
                    layout.update(map, size: geometry.size)
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { model.selectOffset(1); return .handled }
        .onKeyPress(.upArrow) { model.selectOffset(-1); return .handled }
        .onKeyPress(.rightArrow) { model.openSelected(); return .handled }
        .onKeyPress(.leftArrow) { model.up(); return .handled }
        .onKeyPress(.return) { model.openSelected(); return .handled }
        .onKeyPress(.escape) { model.selectedID = nil; return .handled }
    }

    private func openRemaining(_ id: Int?) {
        model.visualMode = false
        model.selectedID = id
    }
}

private struct DiskMapTile: View {
    let tile: RenderedMapTile
    let version: UUID
    @ObservedObject var model: DiskModel
    let focus: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false
    private static let colors: [Color] = [.teal, .blue, .indigo, .mint, .brown, .purple]

    var body: some View {
        let selected = model.selectedID == tile.id
        let color = Self.colors[tile.entry.colorIndex]
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(color.opacity(colorScheme == .dark ? (selected ? 0.4 : 0.21) : (selected ? 0.27 : 0.12)))
            MapTileLabel(tile: tile)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? Color.accentColor : color.opacity(hovered ? 0.65 : 0.17), lineWidth: selected ? 2 : 1)
            if model.basket.contains(tile.id), tile.rect.width > 50, tile.rect.height > 50 {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(10)
            }
        }
        .frame(width: tile.rect.width, height: tile.rect.height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if model.select(tile.id, version: version) { model.openSelected() } }
        .onTapGesture { if model.select(tile.id, version: version) { focus() } }
        .onHover { hovered = $0 }
        .contextMenu {
            NodeMenu(id: tile.id, version: version, model: model)
        }
        .help(tile.entry.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.entry.accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if model.select(tile.id, version: version) { focus() } }
        .accessibilityAction(named: "打开") { if model.select(tile.id, version: version) { model.openSelected() } }
        .offset(x: tile.rect.minX, y: tile.rect.minY)
    }
}

private struct MapTileLabel: View {
    let tile: RenderedMapTile
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if tile.label == .nameAndCapacity {
                Text(tile.entry.name).font(.system(size: tile.large ? 14 : 11, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }
            if tile.label != .none {
                Text(tile.entry.capacity).font(.system(size: tile.large ? 12 : 11).monospacedDigit()).fixedSize()
                    .foregroundStyle(tile.label == .nameAndCapacity ? .secondary : .primary)
            }
        }.padding(tile.padding).frame(width: tile.rect.width, height: tile.rect.height, alignment: .topLeading)
            .clipped().allowsHitTesting(false)
    }
}

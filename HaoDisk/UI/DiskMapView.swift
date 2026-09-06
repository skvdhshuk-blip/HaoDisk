import SwiftUI

struct DiskMapView: View {
    @ObservedObject var model: DiskModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoverID: Int?
    @FocusState private var focused: Bool
    private let colors: [Color] = [.teal, .blue, .indigo, .mint, .brown, .purple]

    var body: some View {
        GeometryReader { geometry in
            let items = model.children.filter { $0.bytes(model.metric) > 0 }.sorted { $0.bytes(model.metric) > $1.bytes(model.metric) }
            let total = items.reduce(0.0) { $0 + Double($1.bytes(model.metric)) }
            let area = geometry.size.width * geometry.size.height
            let shown = Array(items.prefix(80).prefix { Double($0.bytes(model.metric)) / max(total, 1) * area >= 900 })
            let rest = items.dropFirst(shown.count)
            let weights = shown.map { MapWeight(id: $0.id, value: Double($0.bytes(model.metric))) }
                + (rest.isEmpty ? [] : [MapWeight(id: -1, value: rest.reduce(0) { $0 + Double($1.bytes(model.metric)) })])
            let tiles = Treemap.layout(weights, in: CGRect(origin: .zero, size: geometry.size))
            let restTile = tiles.first { $0.id == -1 }
            ZStack(alignment: .topLeading) {
                if weights.isEmpty {
                    ContentUnavailableView("没有可绘制的空间", systemImage: "square.dashed", description: Text("文件仍可在目录列表中查看。"))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                ForEach(tiles) { tile in
                    if tile.id == -1 {
                        RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08))
                            .overlay {
                                if tile.rect.width >= 100 && tile.rect.height >= 50 {
                                    Button { openRemaining(rest.first?.id) } label: {
                                        VStack(spacing: 5) { Text("其余 \(rest.count) 项"); Image(systemName: "arrow.up.right") }
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }.buttonStyle(.plain)
                                }
                            }
                            .frame(width: max(0, tile.rect.width - 3), height: max(0, tile.rect.height - 3))
                            .offset(x: tile.rect.minX + 1.5, y: tile.rect.minY + 1.5)
                    } else if let node = model.snapshot?.nodes[tile.id] {
                        tileView(node, rect: tile.rect)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let restTile, restTile.rect.width < 100 || restTile.rect.height < 50 {
                    Button { openRemaining(rest.first?.id) } label: {
                        Label("其余 \(rest.count) 项", systemImage: "list.bullet")
                            .font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 6)
                    }.buttonStyle(.plain).background(.regularMaterial, in: Capsule()).padding(8)
                        .help("在列表中查看面积过小的项目")
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

    private func tileView(_ node: DiskNode, rect: CGRect) -> some View {
        let selected = model.selectedID == node.id
        let hash = node.name.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let color = colors[Int(hash % UInt64(colors.count))]
        let large = rect.width > 145 && rect.height > 90
        let labelFits = rect.width > 65 && rect.height > 30
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(color.opacity(colorScheme == .dark ? (selected ? 0.4 : 0.21) : (selected ? 0.27 : 0.12)))
            if labelFits {
                VStack(alignment: .leading, spacing: 5) {
                    Text(node.name).font(.system(size: large ? 14 : 11, weight: .medium))
                        .lineLimit(large ? 2 : 1).truncationMode(.middle)
                    if large {
                        Text(node.issueCount > 0 ? "未完整读取" : percentage(node.bytes(model.metric), total: model.current?.bytes(model.metric) ?? 0))
                            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }.padding(large ? 14 : 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? Color.accentColor : color.opacity(hoverID == node.id ? 0.65 : 0.17), lineWidth: selected ? 2 : 1)
            if model.basket.contains(node.id), rect.width > 50, rect.height > 50 {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(10)
            }
        }
        .frame(width: max(0, rect.width - 3), height: max(0, rect.height - 3))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.selectedID = node.id; model.openSelected() }
        .onTapGesture { model.selectedID = node.id; focused = true }
        .onHover { hoverID = $0 ? node.id : nil }
        .contextMenu { NodeMenu(node: node, model: model) }
        .help("\(node.name)\n\(nodeSizeLabel(node, metric: model.metric))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(node.name)，\(nodeSizeLabel(node, metric: model.metric))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectedID = node.id; focused = true }
        .accessibilityAction(named: "打开") { model.selectedID = node.id; model.openSelected() }
        .offset(x: rect.minX + 1.5, y: rect.minY + 1.5)
    }
}

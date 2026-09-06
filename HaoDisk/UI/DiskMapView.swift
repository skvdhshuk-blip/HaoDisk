import SwiftUI
import AppKit

struct DiskMapView: View {
    @ObservedObject var model: DiskModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoverID: Int?
    @FocusState private var focused: Bool
    private let colors: [Color] = [.teal, .blue, .indigo, .mint, .brown, .purple]

    var body: some View {
        GeometryReader { geometry in
            let items = TreemapItems(model.children, metric: model.metric)
            let rest = items.remaining
            let remainingName = "其余 \(rest.count) 项"
            let remainingSize = (rest.contains { $0.issueCount > 0 } ? "已读 " : "") + formattedBytes(items.remainingBytes(model.metric))
            let weights = items.weights(model.metric)
            let tiles = Treemap.layout(weights, in: CGRect(origin: .zero, size: geometry.size))
            let restTile = tiles.first { $0.id == -1 }
            ZStack(alignment: .topLeading) {
                if weights.isEmpty {
                    ContentUnavailableView("没有可绘制的空间", systemImage: "square.dashed", description: Text("文件仍可在目录列表中查看。"))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                ForEach(tiles) { tile in
                    if tile.id == -1 {
                        let rect = displayRect(tile.rect)
                        Button { openRemaining(rest.first?.id) } label: {
                            RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08))
                                .overlay { MapTileLabel(name: remainingName, capacity: remainingSize, size: rect.size) }
                                .frame(width: rect.width, height: rect.height)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .help("\(remainingName) · \(remainingSize)\n在列表中查看")
                            .accessibilityLabel("\(remainingName)，\(remainingSize)，在列表中查看")
                            .offset(x: rect.minX, y: rect.minY)
                    } else if let node = model.snapshot?.nodes[tile.id] {
                        tileView(node, rect: tile.rect)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let restTile, !MapTileLabel(name: remainingName, capacity: remainingSize, size: displayRect(restTile.rect).size).fitsName {
                    Button { openRemaining(rest.first?.id) } label: {
                        Label("\(remainingName) · \(remainingSize)", systemImage: "list.bullet")
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
        let rect = displayRect(rect)
        let selected = model.selectedID == node.id
        let hash = node.name.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let color = colors[Int(hash % UInt64(colors.count))]
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(color.opacity(colorScheme == .dark ? (selected ? 0.4 : 0.21) : (selected ? 0.27 : 0.12)))
            MapTileLabel(name: node.name, capacity: nodeSizeLabel(node, metric: model.metric), size: rect.size)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? Color.accentColor : color.opacity(hoverID == node.id ? 0.65 : 0.17), lineWidth: selected ? 2 : 1)
            if model.basket.contains(node.id), rect.width > 50, rect.height > 50 {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(10)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.selectedID = node.id; model.openSelected() }
        .onTapGesture { model.selectedID = node.id; focused = true }
        .onHover { hoverID = $0 ? node.id : nil }
        .contextMenu { NodeMenu(node: node, model: model) }
        .help("\(node.name)\n\(nodeSizeLabel(node, metric: model.metric))\n" + (node.issueCount > 0 ? "未完整读取" : percentage(node.bytes(model.metric), total: model.current?.bytes(model.metric) ?? 0)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(node.name)，\(nodeSizeLabel(node, metric: model.metric))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectedID = node.id; focused = true }
        .accessibilityAction(named: "打开") { model.selectedID = node.id; model.openSelected() }
        .offset(x: rect.minX, y: rect.minY)
    }

    private func displayRect(_ rect: CGRect) -> CGRect {
        let gap = min(3, min(rect.width, rect.height) * 0.2)
        return rect.insetBy(dx: gap / 2, dy: gap / 2)
    }
}

private struct MapTileLabel: View {
    let name: String
    let capacity: String
    let size: CGSize

    private var large: Bool { size.width > 145 && size.height > 90 }
    private var padding: CGFloat { large ? 14 : 4 }
    private var compactPadding: CGFloat { 2 }
    private var nameFont: NSFont { .systemFont(ofSize: large ? 14 : 11, weight: .medium) }
    private var sizeFont: NSFont { .monospacedDigitSystemFont(ofSize: large ? 12 : 11, weight: .regular) }
    private var capacitySize: CGSize { (capacity as NSString).size(withAttributes: [.font: sizeFont]) }
    private var lineHeight: CGFloat { ceil(nameFont.ascender - nameFont.descender + nameFont.leading) }

    private var fitsSize: Bool {
        ceil(capacitySize.width) + compactPadding * 2 <= size.width && ceil(capacitySize.height) + compactPadding * 2 <= size.height
    }
    var fitsName: Bool {
        ceil(capacitySize.width) + padding * 2 <= size.width
            && lineHeight + 4 + ceil(capacitySize.height) + padding * 2 <= size.height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if fitsName {
                Text(name).font(Font(nameFont)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if fitsSize {
                Text(capacity).font(Font(sizeFont)).fixedSize()
                    .foregroundStyle(fitsName ? .secondary : .primary)
            }
        }.padding(fitsName ? padding : compactPadding).frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped().allowsHitTesting(false)
    }
}

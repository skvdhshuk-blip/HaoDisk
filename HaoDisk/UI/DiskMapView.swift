import SwiftUI

struct DiskMapView: View {
    @ObservedObject var model: DiskModel
    @State private var hoverID: Int?
    private let colors: [Color] = [
        Color(red: 0.08, green: 0.48, blue: 0.48), Color(red: 0.16, green: 0.56, blue: 0.60),
        Color(red: 0.28, green: 0.48, blue: 0.64), Color(red: 0.41, green: 0.49, blue: 0.66),
        Color(red: 0.36, green: 0.57, blue: 0.53), Color(red: 0.53, green: 0.50, blue: 0.64)
    ]

    var body: some View {
        let items = model.children.filter { $0.bytes(model.metric) > 0 }
        let shown = Array(items.prefix(100))
        let rest = items.dropFirst(100)
        let weights = shown.map { MapWeight(id: $0.id, value: Double($0.bytes(model.metric))) }
            + (rest.isEmpty ? [] : [MapWeight(id: -1, value: rest.reduce(0) { $0 + Double($1.bytes(model.metric)) })])
        VStack(alignment: .leading, spacing: 10) {
            if weights.isEmpty {
                ContentUnavailableView("没有可绘制的空间", systemImage: "square.dashed", description: Text("零字节文件与仅存云端的项目仍可在列表查看。"))
            } else {
                GeometryReader { geometry in
                    let tiles = Treemap.layout(weights, in: CGRect(origin: .zero, size: geometry.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(tiles) { tile in
                            if tile.id == -1 {
                                Button { model.visualMode = false } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: "ellipsis")
                                        if tile.rect.width > 75 && tile.rect.height > 65 { Text("其余 \(rest.count) 项").font(.caption) }
                                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                                }.buttonStyle(.plain).background(.quaternary)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                                    .frame(width: max(0, tile.rect.width - 5), height: max(0, tile.rect.height - 5))
                                    .offset(x: tile.rect.minX + 2.5, y: tile.rect.minY + 2.5)
                                    .help("切换到列表查看其余 \(rest.count) 项")
                            } else if let node = model.snapshot?.nodes[tile.id] {
                                tileView(node, rect: tile.rect, color: colors[(shown.firstIndex(where: { $0.id == node.id }) ?? 0) % colors.count])
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "cursorarrow")
                Text("单击选择 · 双击进入 · 右键查看更多")
                Spacer()
                let emptyCount = model.children.filter { $0.bytes(model.metric) == 0 && $0.issueCount == 0 }.count
                if emptyCount > 0 { Text("\(emptyCount) 个零大小项目见左侧") }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private func tileView(_ node: DiskNode, rect: CGRect, color: Color) -> some View {
        let selected = model.selectedID == node.id
        let large = rect.width > 145 && rect.height > 125
        let medium = rect.width > 85 && rect.height > 62
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(color.gradient)
            if medium {
                VStack(spacing: large ? 9 : 4) {
                    if large {
                        Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                            .font(.system(size: 32, weight: .light)).foregroundStyle(.white.opacity(0.82))
                    }
                    Text(node.name).font(large ? .system(size: 17, weight: .medium) : .caption.weight(.medium))
                        .lineLimit(2).multilineTextAlignment(.center)
                    Text(formattedBytes(node.bytes(model.metric))).font(large ? .system(size: 21, weight: .semibold, design: .rounded) : .caption)
                        .monospacedDigit()
                    if large { Text(percentage(node.bytes(model.metric), total: model.current?.bytes(model.metric) ?? 0)).font(.caption).opacity(0.8) }
                }.foregroundStyle(.white).padding(10)
            }
            RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.primary : .white.opacity(hoverID == node.id ? 0.9 : 0.15), lineWidth: selected ? 3 : 1)
            if model.basket.contains(node.id), rect.width > 35, rect.height > 35 {
                VStack { HStack { Spacer(); Image(systemName: "checkmark.circle.fill").foregroundStyle(.white).padding(9) }; Spacer() }
            }
        }
        .frame(width: max(0, rect.width - 5), height: max(0, rect.height - 5))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2) { if node.canNavigate { model.navigate(node.id) } }
        .onTapGesture { model.selectedID = node.id }
        .onHover { hoverID = $0 ? node.id : nil }
        .contextMenu { NodeMenu(node: node, model: model) }
        .help("\(node.name) · \(formattedBytes(node.bytes(model.metric))) · \(percentage(node.bytes(model.metric), total: model.current?.bytes(model.metric) ?? 0))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(node.name)，\(formattedBytes(node.bytes(model.metric)))，\(percentage(node.bytes(model.metric), total: model.current?.bytes(model.metric) ?? 0))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selectedID = node.id }
        .accessibilityAction(named: "进入文件夹") { model.navigate(node.id) }
        .offset(x: rect.minX + 2.5, y: rect.minY + 2.5)
    }
}

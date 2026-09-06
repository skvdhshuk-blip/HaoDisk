import SwiftUI

struct CleanupReview: View {
    @ObservedObject var model: DiskModel
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "trash").font(.system(size: 30)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text("确认待清理项目").font(.title2.weight(.semibold))
                    Text("\(model.basket.count) 项 · \(formattedBytes(model.basketBytes)) \(model.metric.rawValue)")
                        .foregroundStyle(.secondary)
                }
            }
            Text("请检查每个项目。文件夹会连同其中的全部内容一起移到废纸篓。这里的大小是扫描时的估计，不代表实际可释放空间。")
                .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            List(model.basketNodes) { node in
                HStack {
                    Image(systemName: node.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.name).fontWeight(.medium)
                        Text(node.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    Text(formattedBytes(node.bytes(model.metric))).monospacedDigit()
                    Button { model.basket.remove(node.id); confirmed = false } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).disabled(model.isCleaning).help("从清单移除")
                }.padding(.vertical, 6)
            }.frame(height: 240)
            Label("移到废纸篓后仍占用空间。可在 Finder 的废纸篓中找回，清空需由你自行操作。", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("我已检查清单，确认不再需要这些项目", isOn: $confirmed).disabled(model.isCleaning)
            HStack {
                if model.isCleaning { ProgressView().controlSize(.small); Text("正在移到废纸篓…").font(.callout) }
                Spacer()
                Button("取消") { model.showReview = false }.keyboardShortcut(.cancelAction).disabled(model.isCleaning)
                Button("移到废纸篓", role: .destructive) { model.trashReviewedItems() }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(!confirmed || model.basket.isEmpty || model.isCleaning)
            }
        }.padding(26).frame(width: 640).interactiveDismissDisabled(model.isCleaning)
    }
}

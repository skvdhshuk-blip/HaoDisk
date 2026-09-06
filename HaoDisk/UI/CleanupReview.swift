import SwiftUI

struct CleanupReview: View {
    @ObservedObject var model: DiskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("待清理").font(.title3.weight(.semibold))
                Spacer()
                Text("\(model.basket.count) 项 · \(formattedBytes(model.basketBytes))")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            List(model.basketNodes) { node in
                HStack(spacing: 12) {
                    Image(systemName: node.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.name).fontWeight(.medium).lineLimit(2).truncationMode(.middle)
                        Text(node.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(node.url.path)
                    }
                    Spacer(minLength: 12)
                    Text(formattedBytes(node.bytes(model.metric))).font(.callout).monospacedDigit()
                    Button { model.basket.remove(node.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).disabled(model.isCleaning).help("从清单移除")
                }.padding(.vertical, 6)
            }.listStyle(.inset).frame(height: min(320, max(100, CGFloat(model.basket.count) * 65)))
            if model.snapshot?.stoppedEarly == true {
                Text("扫描仅包含部分结果。移动前会完整核对所选文件夹；内容不全或已变化的项目不会移动。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("文件夹将连同全部内容移到废纸篓。可在 Finder 中找回；清空前仍占用空间。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.isCleaning { ProgressView().controlSize(.small); Text("正在核对并移动…").font(.callout) }
                Spacer()
                Button("取消") { model.showReview = false }.keyboardShortcut(.cancelAction).disabled(model.isCleaning)
                Button("移到废纸篓", role: .destructive) { model.trashReviewedItems() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.basket.isEmpty || model.isCleaning || model.cleanupInvalid)
            }
        }.padding(24).frame(width: 600).interactiveDismissDisabled(model.isCleaning)
    }
}

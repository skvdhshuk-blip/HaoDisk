import SwiftUI

private let diskAccent = Color(red: 0.03, green: 0.48, blue: 0.47)

struct ContentView: View {
    @ObservedObject var model: DiskModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isScanning { scanningView }
            else if let snapshot = model.snapshot { analysisView(snapshot) }
            else { welcomeView }
        }
        .tint(diskAccent)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive.fill").foregroundStyle(diskAccent)
                    Text("HaoDisk").font(.headline)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.hasAccess {
                    Button { model.scan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                        .disabled(model.isBusy)
                }
                Button { model.chooseFolder() } label: { Label("选择文件夹", systemImage: "folder.badge.plus") }
                    .disabled(model.isBusy)
                Menu {
                    Button("关于容量与权限") { model.showHelp = true }
                    if model.hasBookmark {
                        Button("忘记文件夹授权") { model.forgetFolder() }.disabled(model.isBusy)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .help("权限与说明")
            }
        }
        .sheet(isPresented: $model.showReview) { CleanupReview(model: model) }
        .sheet(isPresented: $model.showIssues) { issuesView }
        .sheet(isPresented: $model.showHelp) { helpView }
        .alert("HaoDisk", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var welcomeView: some View {
        VStack(spacing: 24) {
            Spacer()
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 14).fill(diskAccent).frame(width: 53, height: 110)
                VStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 13).fill(diskAccent.opacity(0.7)).frame(width: 60, height: 63)
                    RoundedRectangle(cornerRadius: 11).fill(diskAccent.opacity(0.35)).frame(width: 60, height: 40)
                }
            }.accessibilityHidden(true)
            VStack(spacing: 12) {
                Text("把空间，看明白。").font(.system(size: 34, weight: .semibold))
                Text("从一个文件夹开始，找到占空间的大文件。\n看清每一项，再决定要不要清理。")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            }
            HStack(spacing: 12) {
                Button("选择文件夹…") { model.chooseFolder() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isBusy)
                if model.hasBookmark {
                    Button("继续上次分析") { model.restoreFolder() }.controlSize(.large).disabled(model.isBusy)
                }
            }
            HStack(spacing: 28) {
                Label("本地分析", systemImage: "lock.shield")
                Label("按需授权", systemImage: "folder.badge.person.crop")
                Label("移到废纸篓", systemImage: "trash")
            }.font(.callout).foregroundStyle(.secondary).padding(.top, 12)
            Spacer()
            Text("只访问你选择的目录。不会自动清理或上传文件。")
                .font(.callout).foregroundStyle(.secondary).padding(.bottom, 28)
        }.frame(maxWidth: .infinity)
    }

    private var scanningView: some View {
        VStack(spacing: 22) {
            ProgressView().controlSize(.large)
            Text("正在整理空间…").font(.title2.weight(.semibold))
            Text("已检查 \(model.progress.count.formatted()) 项 · \(formattedBytes(model.progress.bytes))")
                .font(.title3.monospacedDigit())
            Text(model.progress.folder).lineLimit(1).foregroundStyle(.secondary).frame(maxWidth: 420)
            Button("停止扫描，查看已读结果") { model.cancelScan() }
            Text("扫描期间不会修改文件").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func analysisView(_ snapshot: DiskSnapshot) -> some View {
        VStack(spacing: 0) {
            capacityHeader(snapshot)
            Divider()
            navigationBar(snapshot)
            Divider()
            if snapshot.stoppedEarly || snapshot.issueCount > 0 {
                HStack {
                    Label(snapshot.stoppedEarly ? "扫描未完成，当前显示已读结果" : "有 \(snapshot.issueCount) 处未完整读取，容量可能偏小", systemImage: "exclamationmark.triangle")
                    Spacer()
                    if !snapshot.issues.isEmpty { Button("查看详情") { model.showIssues = true } }
                }.font(.callout).padding(.horizontal, 20).padding(.vertical, 9)
                    .background(Color.orange.opacity(0.1))
            }
            if !model.outcomes.isEmpty { outcomeBanner }
            HSplitView {
                directoryList.frame(minWidth: 300, idealWidth: 330, maxWidth: 460)
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.current?.name ?? "").font(.title2.weight(.semibold)).lineLimit(1)
                            Text("\(model.children.count) 个直接项目 · 双击文件夹进入")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(model.current.map { nodeSizeLabel($0, metric: model.metric) } ?? "")
                            .font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
                    }
                    if model.children.isEmpty {
                        ContentUnavailableView(model.current?.issueCount ?? 0 > 0 ? "无法完整读取此目录" : "这个文件夹是空的", systemImage: "folder", description: Text(model.current?.issueCount ?? 0 > 0 ? "请查看权限问题详情，或重新选择目录。" : "可以返回上层继续分析。"))
                    } else if model.visualMode {
                        DiskMapView(model: model)
                    } else {
                        detailList
                    }
                }.padding(22).frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            selectionBar
            Divider()
            HStack {
                Label("\(snapshot.nodes.count - 1) 项 · 扫描用时 \(snapshot.elapsed.formatted(.number.precision(.fractionLength(1)))) 秒", systemImage: "checkmark.circle")
                Spacer()
                Text("硬链接计一次 · 面积代表\(model.metric.rawValue) · 不等于可释放容量")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
        }
    }

    private func capacityHeader(_ snapshot: DiskSnapshot) -> some View {
        HStack(spacing: 18) {
            Image(systemName: "internaldrive").font(.system(size: 32)).foregroundStyle(diskAccent)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("磁盘空间").font(.headline)
                    Text("卷容量").font(.caption).foregroundStyle(.secondary)
                }
                if let total = snapshot.totalCapacity, let available = snapshot.availableCapacity {
                    Text("可用 \(formattedBytes(available)) / 共 \(formattedBytes(total))").font(.callout).foregroundStyle(.secondary)
                } else { Text("卷容量不可用").font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("本次已读 · \(formattedBytes(snapshot.root.bytes(model.metric)))").font(.headline)
                Label("仅限已授权目录", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }
            if let total = snapshot.totalCapacity, let available = snapshot.availableCapacity, total > 0 {
                Gauge(value: Double(max(0, min(total, total - available))), in: 0...Double(total)) {
                    Text("磁盘已用")
                }.gaugeStyle(.accessoryCircularCapacity).tint(diskAccent).scaleEffect(0.88)
            }
        }.padding(.horizontal, 24).padding(.vertical, 19)
    }

    private func navigationBar(_ snapshot: DiskSnapshot) -> some View {
        HStack(spacing: 14) {
            Button { model.back() } label: { Image(systemName: "chevron.left") }.disabled(!model.canGoBack).help("后退")
            Button { model.forward() } label: { Image(systemName: "chevron.right") }.disabled(!model.canGoForward).help("前进")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(snapshot.ancestors(of: model.currentID), id: \.self) { id in
                        if id != 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        Button { model.navigate(id) } label: {
                            HStack(spacing: 5) {
                                if id == 0 { Image(systemName: "folder.fill").foregroundStyle(diskAccent) }
                                Text(snapshot.nodes[id].name).lineLimit(1)
                            }
                        }.buttonStyle(.plain).help(snapshot.nodes[id].url.path)
                    }
                }
            }
            Picker("统计方式", selection: $model.metric) {
                ForEach(SizeMetric.allCases) { metric in Text(metric.rawValue).tag(metric) }
            }.labelsHidden().frame(width: 115).help("占用空间是磁盘分配给文件的大小；文件大小是内容的逻辑长度。")
            Toggle("面积图", isOn: $model.visualMode).toggleStyle(.switch).controlSize(.small).fixedSize()
        }.buttonStyle(.borderless).padding(.horizontal, 22).padding(.vertical, 12)
    }

    private var directoryList: some View {
        List(selection: $model.selectedID) {
            ForEach(model.children) { node in
                DirectoryRow(node: node, total: model.current?.bytes(model.metric) ?? 0,
                             metric: model.metric, queued: model.basket.contains(node.id))
                    .tag(node.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if node.canNavigate { model.navigate(node.id) } }
                    .onTapGesture { model.selectedID = node.id }
                    .contextMenu { NodeMenu(node: node, model: model) }
                    .accessibilityAction { model.selectedID = node.id }
                    .accessibilityAction(named: "进入文件夹") { model.navigate(node.id) }
                    .accessibilityAction(named: "加入待清理") { model.add(node) }
            }
        }.listStyle(.sidebar)
    }

    private var detailList: some View {
        Table(model.children, selection: $model.selectedID) {
            TableColumn("名称") { node in
                Label(node.name, systemImage: node.isDirectory ? "folder.fill" : "doc")
                    .onTapGesture(count: 2) { model.navigate(node.id) }
                    .onTapGesture { model.selectedID = node.id }
                    .contextMenu { NodeMenu(node: node, model: model) }
            }
            TableColumn("占用空间") { node in Text(nodeSizeLabel(node, metric: .allocated)).monospacedDigit() }.width(100)
            TableColumn("文件大小") { node in Text(nodeSizeLabel(node, metric: .logical)).monospacedDigit() }.width(100)
            TableColumn("占比") { node in
                Text(node.issueCount > 0 ? "—" : percentage(node.bytes(model.metric), total: model.current?.bytes(model.metric) ?? 0)).monospacedDigit()
            }.width(60)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            if let node = model.selected {
                Image(systemName: node.isDirectory ? "folder" : "doc").foregroundStyle(diskAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(selectionDescription(node)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 16)
                if node.canNavigate { Button("进入文件夹") { model.navigate(node.id) } }
                Button("在 Finder 中显示") { model.reveal(node) }
                Button { model.add(node) } label: { Label("加入待清理", systemImage: "plus") }
                    .disabled(model.snapshot.map { CleanupPolicy.reason(for: node.id, in: $0) != nil } ?? true)
            } else {
                Text("选择项目查看详情，双击文件夹继续分析").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            Button { model.showReview = true } label: {
                Label("待清理 \(model.basket.count)", systemImage: "tray.full")
            }.buttonStyle(.borderedProminent).disabled(model.basket.isEmpty)
        }.padding(.horizontal, 20).padding(.vertical, 15).frame(minHeight: 70)
    }

    private func selectionDescription(_ node: DiskNode) -> String {
        if let snapshot = model.snapshot, let reason = CleanupPolicy.reason(for: node.id, in: snapshot) { return reason }
        if node.isHardLinkDuplicate { return "硬链接：其空间已在本次扫描的另一项中计入。" }
        return node.url.path
    }

    private var outcomeBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("已移到废纸篓 \(model.outcomes.filter { $0.error == nil }.count) 项；废纸篓清空前仍占用磁盘空间。")
                Spacer()
                Button("收起") { model.outcomes = [] }
            }
            ForEach(model.outcomes.filter { $0.error != nil }, id: \.id) { item in
                Text("\(item.name)：\(item.error ?? "")").foregroundStyle(.orange).textSelection(.enabled)
            }
        }.font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(diskAccent.opacity(0.08))
    }

    private var issuesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("未完整读取的项目").font(.title2.weight(.semibold))
            Text("macOS 权限、其他挂载卷或扫描上限可能导致遗漏。下面最多显示 100 条记录，缺失内容不计入图表。")
                .foregroundStyle(.secondary)
            List(model.snapshot?.issues ?? []) { issue in
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.path).lineLimit(2).textSelection(.enabled)
                    Text(issue.message).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }.frame(height: 320)
            HStack { Spacer(); Button("完成") { model.showIssues = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 620)
    }

    private var helpView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("看懂容量，管理授权").font(.title2.weight(.semibold))
            helpRow("folder.badge.person.crop", "只分析你选择的目录", "可以选择主目录、外置磁盘或单个文件夹。部分受系统保护的内容仍可能无法访问。菜单中的“忘记文件夹授权”会删除保存的授权记录。")
            helpRow("square.split.2x2", "面积代表本次读取的大小", "占用空间与文件大小可能不同。硬链接计一次；APFS 克隆、快照、压缩和云端文件可能导致结果与磁盘已用容量不同。不会主动下载云端文件。")
            helpRow("trash", "清理始终由你确认", "先加入清单，再移到系统废纸篓。系统目录、Library 和应用资料包仅供分析。可在 Finder 的废纸篓中找回；只有清空废纸篓后才可能释放空间。")
            helpRow("lock.shield", "文件留在你的 Mac", "无需登录，没有广告、追踪、联网服务或文件上传。只保存上次选择的目录授权，不保存扫描明细。")
            HStack { Spacer(); Button("知道了") { model.showHelp = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 580)
    }

    private func helpRow(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(diskAccent).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
        }
    }
}

struct DirectoryRow: View {
    let node: DiskNode
    let total: Int64
    let metric: SizeMetric
    let queued: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: node.identity.isLink ? "link" : node.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 26)).foregroundStyle(node.isDirectory ? diskAccent : .secondary).frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(node.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    if queued { Image(systemName: "checkmark.circle.fill").foregroundStyle(diskAccent) }
                    if node.issueCount > 0 { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    Spacer(minLength: 4)
                    Text(nodeSizeLabel(node, metric: metric)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Text(node.issueCount > 0 ? "未完整读取" : node.isDirectory ? "\(node.descendantCount.formatted()) 项" : node.identity.isLink ? "符号链接" : "文件")
                    Spacer()
                    Text(node.issueCount > 0 ? "—" : percentage(node.bytes(metric), total: total))
                }.font(.caption).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    Capsule().fill(diskAccent.opacity(0.16))
                    Capsule().fill(diskAccent.opacity(0.6)).frame(width: geometry.size.width * ratio(node.bytes(metric), total: total))
                }.frame(height: 3)
            }
            if node.canNavigate { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
        }.padding(.vertical, 10)
    }
}

struct NodeMenu: View {
    let node: DiskNode
    @ObservedObject var model: DiskModel
    var body: some View {
        if node.canNavigate { Button("进入文件夹") { model.navigate(node.id) } }
        Button("在 Finder 中显示") { model.reveal(node) }
        Divider()
        if model.basket.contains(node.id) {
            Button("从待清理移除") { model.basket.remove(node.id) }
        } else {
            Button("加入待清理") { model.add(node) }
                .disabled(model.snapshot.map { CleanupPolicy.reason(for: node.id, in: $0) != nil } ?? true)
        }
    }
}

func ratio(_ value: Int64, total: Int64) -> Double { total > 0 ? min(1, max(0, Double(value) / Double(total))) : 0 }
func percentage(_ value: Int64, total: Int64) -> String { ratio(value, total: total).formatted(.percent.precision(.fractionLength(1))) }

func nodeSizeLabel(_ node: DiskNode, metric: SizeMetric) -> String {
    if node.issueCount > 0 { return node.bytes(metric) > 0 ? "已读 \(formattedBytes(node.bytes(metric)))" : "未读取" }
    return formattedBytes(node.bytes(metric))
}

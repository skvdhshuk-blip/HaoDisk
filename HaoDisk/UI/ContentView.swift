import SwiftUI

struct ContentView: View {
    @ObservedObject var model: DiskModel
    @State private var showVolume = false

    var body: some View {
        VStack(spacing: 0) {
            if model.hasAccess || model.snapshot != nil {
                pathBar
                Divider()
            }
            if let snapshot = model.snapshot {
                workspace(snapshot).disabled(model.isBusy)
                Divider()
                statusBar(snapshot)
            } else if model.isScanning {
                scanningView
            } else {
                welcomeView
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.back() } label: { Image(systemName: "chevron.left") }
                    .help("后退（⌘[）").disabled(!model.canGoBack || model.isBusy)
                Button { model.forward() } label: { Image(systemName: "chevron.right") }
                    .help("前进（⌘]）").disabled(!model.canGoForward || model.isBusy)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.chooseFolder() } label: { Label("选择文件夹", systemImage: "folder.badge.plus") }
                    .help("选择文件夹（⌘O）").disabled(model.isBusy)
                if model.hasAccess {
                    Button { model.isScanning ? model.cancelScan() : model.scan() } label: {
                        Label(model.isScanning ? "停止扫描" : "重新扫描", systemImage: model.isScanning ? "stop.circle" : "arrow.clockwise")
                    }.help(model.isScanning ? "停止并保留已读取的结果" : "重新扫描（⌘R）").disabled(model.isCleaning)
                }
                if model.snapshot != nil {
                    Picker("视图", selection: $model.visualMode) {
                        Image(systemName: "square.split.2x2").help("面积图（⌘1）").tag(true)
                        Image(systemName: "list.bullet").help("列表（⌘2）").tag(false)
                    }.pickerStyle(.segmented).frame(width: 76)
                    Button { model.showInspector.toggle() } label: { Label("显示简介", systemImage: "info.circle") }
                        .help("显示简介（⌘I）").disabled(model.selected == nil || model.isBusy)
                        .popover(isPresented: $model.showInspector, arrowEdge: .bottom) { inspector }
                    Button { model.reviewSelected() } label: { Label("清理所选项目…", systemImage: "trash") }
                        .help(model.selectedCleanupReason ?? "清理所选项目（⌘⌫）")
                        .disabled(model.selected == nil || model.selectedCleanupReason != nil || model.isBusy)
                }
                if !model.basket.isEmpty {
                    Button { model.showReview = true } label: { Label("待清理 \(model.basket.count)", systemImage: "tray.full") }
                        .labelStyle(.titleAndIcon)
                        .disabled(model.isBusy)
                }
                Menu {
                    Button("容量与权限说明") { model.showHelp = true }
                    if model.hasBookmark { Button("忘记文件夹授权") { model.forgetFolder() }.disabled(model.isBusy) }
                } label: { Image(systemName: "ellipsis.circle") }.help("更多")
            }
        }
        .sheet(isPresented: $model.showReview) { CleanupReview(model: model) }
        .sheet(isPresented: $model.showIssues) { issuesView }
        .sheet(isPresented: $model.showResults) { resultsView }
        .sheet(isPresented: $model.showHelp) { helpView }
        .alert("HaoDisk", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var welcomeView: some View {
        VStack(spacing: 22) {
            Image(systemName: "square.split.2x2").font(.system(size: 54, weight: .ultraLight)).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("分析磁盘空间").font(.system(size: 26, weight: .semibold))
                Text("选择文件夹，查看空间分布并整理不再需要的文件。")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("选择文件夹…") { model.chooseFolder() }.buttonStyle(.borderedProminent)
                if model.hasBookmark { Button("打开上次的文件夹") { model.restoreFolder() } }
            }.controlSize(.large).disabled(model.isBusy)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.regular)
            Text("正在扫描 \(model.progress.folder)").font(.headline).lineLimit(1).truncationMode(.middle)
            Text("\(model.progress.count.formatted()) 项 · \(formattedBytes(model.progress.bytes))")
                .monospacedDigit().foregroundStyle(.secondary)
            Button("停止扫描") { model.cancelScan() }.buttonStyle(.link)
        }.frame(maxWidth: 400).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func breadcrumbs(_ snapshot: DiskSnapshot) -> some View {
        let ancestors = snapshot.ancestors(of: model.currentID)
        return HStack(spacing: 9) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            if ancestors.count > 3 {
                Menu {
                    ForEach(Array(ancestors.dropLast(2)), id: \.self) { id in
                        Button(snapshot.nodes[id].name) { model.navigate(id) }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            ForEach(ancestors.count > 3 ? Array(ancestors.suffix(2)) : ancestors, id: \.self) { id in
                if id != (ancestors.count > 3 ? ancestors[ancestors.count - 2] : 0) {
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Button { model.navigate(id) } label: {
                    Text(snapshot.nodes[id].name).fontWeight(id == model.currentID ? .medium : .regular)
                        .lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain).foregroundStyle(id == model.currentID ? .primary : .secondary)
                    .help(snapshot.nodes[id].url.path)
                    .layoutPriority(id == model.currentID ? 1 : 0)
            }
        }.disabled(model.isBusy)
    }

    private var pathBar: some View {
        HStack(spacing: 16) {
            Group {
                if let snapshot = model.snapshot {
                    breadcrumbs(snapshot)
                } else {
                    Label(model.rootFolderName, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).clipped()
            Button { showVolume.toggle() } label: {
                Text("磁盘可用 \(model.volumeCapacity?.available.map(formattedBytes) ?? "—") / 共 \(model.volumeCapacity?.total.map(formattedBytes) ?? "—")")
                    .monospacedDigit()
            }.buttonStyle(.plain).fixedSize()
                .help("所选文件夹所在磁盘的可用空间与总容量")
                .popover(isPresented: $showVolume, arrowEdge: .bottom) { volumeDetails }
            if model.snapshot != nil {
                Menu {
                    Picker("统计方式", selection: $model.metric) {
                        ForEach(SizeMetric.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    Picker("排序", selection: $model.sort) {
                        ForEach(DirectorySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    HStack(spacing: 5) { Text(model.metric.rawValue); Image(systemName: "line.3.horizontal.decrease") }
                }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary).help("统计方式与排序")
                    .disabled(model.isBusy)
            }
        }.font(.system(size: 12)).padding(.horizontal, 16).frame(height: 37)
    }

    @ViewBuilder private func workspace(_ snapshot: DiskSnapshot) -> some View {
        if model.children.isEmpty {
            let partial = snapshot.stoppedEarly || (model.current?.issueCount ?? 0) > 0
            ContentUnavailableView(partial ? "没有已读取的项目" : "这个文件夹是空的", systemImage: partial ? "folder.badge.questionmark" : "folder", description: Text(partial ? "重新扫描或查看读取问题。" : "返回上层继续分析。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visualMode {
            HSplitView {
                DirectoryTable(model: model).frame(minWidth: 270, idealWidth: 330, maxWidth: 400)
                DiskMapView(model: model).padding(8).frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            DirectoryTable(model: model, detailed: true).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statusBar(_ snapshot: DiskSnapshot) -> some View {
        HStack(spacing: 14) {
            if model.isScanning {
                ProgressView().controlSize(.mini)
                Text("正在扫描 · \(model.progress.count.formatted()) 项").monospacedDigit()
            } else {
                Text("\(model.directoryCount.formatted()) 项").monospacedDigit()
                Text(model.current.map { nodeSizeLabel($0, metric: model.metric) } ?? "").monospacedDigit()
                if snapshot.stoppedEarly || snapshot.issueCount > 0 {
                    Button { model.showIssues = true } label: {
                        Label(snapshot.stopReason?.title ?? "\(snapshot.issueCount) 处未读取", systemImage: "exclamationmark.triangle")
                    }.foregroundStyle(.orange)
                }
                if !model.outcomes.isEmpty {
                    Button { model.showResults = true } label: {
                        Label(resultSummary, systemImage: model.outcomes.contains { $0.error != nil } ? "exclamationmark.circle" : "checkmark.circle")
                    }
                }
            }
            Spacer(minLength: 12)
        }.font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.plain)
            .padding(.horizontal, 16).frame(height: 31)
    }

    private var resultSummary: String {
        let failures = model.outcomes.filter { $0.error != nil }.count
        let moved = model.outcomes.count - failures
        if failures == 0 { return "已移到废纸篓 \(moved) 项" }
        return moved > 0 ? "已移动 \(moved) 项，\(failures) 项未能移动" : "\(failures) 项未能移动"
    }

    @ViewBuilder private var inspector: some View {
        if let node = model.selected {
            VStack(alignment: .leading, spacing: 18) {
                Label { Text(node.name).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: node.isDirectory ? "folder.fill" : "doc").foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 10) {
                    infoRow("占用空间", nodeSizeLabel(node, metric: .allocated))
                    infoRow("文件大小", nodeSizeLabel(node, metric: .logical))
                    if node.isDirectory { infoRow(node.issueCount > 0 || model.snapshot?.stoppedEarly == true ? "已读项目" : "包含", "\(node.descendantCount.formatted()) 项") }
                    if node.issueCount == 0 { infoRow("当前目录占比", percentage(node.bytes(model.metric), total: model.current?.bytes(model.metric) ?? 0)) }
                }.font(.callout)
                Text(node.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let reason = model.selectedCleanupReason { Label(reason, systemImage: "lock").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if node.isHardLinkDuplicate { Text("硬链接：空间已在本次扫描的另一项中计入。").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("在 Finder 中显示") { model.reveal(node) }
                    Spacer()
                    if model.basket.contains(node.id) {
                        Button("移出清单") { model.basket.remove(node.id) }
                    } else {
                        Button("加入待清理") { model.add(node) }.disabled(model.selectedCleanupReason != nil)
                    }
                }
            }.padding(22).frame(width: 340)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).monospacedDigit().textSelection(.enabled) }
    }

    private var volumeDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("所在磁盘", systemImage: "internaldrive").font(.headline)
            if let total = model.volumeCapacity?.total, let available = model.volumeCapacity?.available, total > 0 {
                ProgressView(value: Double(max(0, total - available)), total: Double(total))
            }
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                infoRow("磁盘总容量", model.volumeCapacity?.total.map(formattedBytes) ?? "—")
                infoRow("可用空间", model.volumeCapacity?.available.map(formattedBytes) ?? "—")
                if let snapshot = model.snapshot {
                    infoRow("本次已读", formattedBytes(snapshot.root.bytes(model.metric)))
                }
            }
            Text("图表只包含所选目录的已读内容。共享块、快照和废纸篓会影响实际可释放空间。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(width: 300)
    }

    private var issuesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.snapshot?.stopReason?.title ?? "未读取的项目").font(.title3.weight(.semibold))
            Text(model.snapshot?.stopReason?.explanation ?? "这些项目未计入大小。可重新选择目录授权，或在 Finder 中检查访问权限。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !(model.snapshot?.issues.isEmpty ?? true) {
                List(model.snapshot?.issues ?? []) { issue in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(issue.path).textSelection(.enabled)
                        Text(issue.message).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }.frame(height: min(280, max(100, CGFloat(model.snapshot?.issues.count ?? 0) * 80)))
                if (model.snapshot?.issueCount ?? 0) > 100 { Text("显示前 100 处读取问题").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                if case .nodeLimit = model.snapshot?.stopReason {
                    Button("选择较小的文件夹…") { model.showIssues = false; model.chooseFolder() }
                } else {
                    Button("重新扫描") { model.showIssues = false; model.scan() }
                }
                Spacer()
                Button("完成") { model.showIssues = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 560)
    }

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(resultSummary).font(.title3.weight(.semibold))
            List(model.outcomes, id: \.id) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.error == nil ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(item.error == nil ? Color.secondary : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).fontWeight(.medium)
                        Text(item.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let error = item.error { Text(error).font(.callout).foregroundStyle(.orange) }
                    }
                }.padding(.vertical, 5)
            }.frame(height: min(280, max(100, CGFloat(model.outcomes.count) * 80)))
            if model.outcomes.contains(where: { $0.error == nil }) {
                Text("在 Finder 的废纸篓中可找回文件；清空后才可能释放空间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("完成") { model.showResults = false; model.outcomes = [] }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 560)
    }

    private var helpView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("容量与权限").font(.title3.weight(.semibold))
            helpRow("访问范围", "HaoDisk 只访问你通过系统选择器授权的目录。部分受系统保护的内容仍可能无法读取。可在更多菜单中忘记保存的授权。")
            helpRow("大小的含义", "占用空间是磁盘分配给文件的大小，文件大小是内容的逻辑长度。硬链接计一次；APFS 克隆、快照和云端占位文件会影响统计。不会主动下载文件。")
            helpRow("清理与隐私", "只在你审阅清单后移到废纸篓。系统目录、Library 和应用资料包仅供分析。文件及扫描结果留在本机，无上传或追踪。")
            HStack { Spacer(); Button("完成") { model.showHelp = false }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 480)
    }

    private func helpRow(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
        }
    }
}

struct NodeMenu: View {
    let node: DiskNode
    @ObservedObject var model: DiskModel
    var body: some View {
        if node.canNavigate { Button("打开文件夹") { model.navigate(node.id) } }
        Button("显示简介") { model.selectedID = node.id; model.showInspector = true }
        Button("在 Finder 中显示") { model.reveal(node) }
        Divider()
        if model.basket.contains(node.id) { Button("从待清理移除") { model.basket.remove(node.id) } }
        else {
            Button("加入待清理") { model.add(node) }
                .disabled(model.snapshot.map { CleanupPolicy.reason(for: node.id, in: $0) != nil } ?? true)
        }
    }
}

func ratio(_ value: Int64, total: Int64) -> Double { total > 0 ? min(1, max(0, Double(value) / Double(total))) : 0 }
func percentage(_ value: Int64, total: Int64) -> String {
    let share = ratio(value, total: total)
    return share > 0 && share < 0.001 ? "<0.1%" : share.formatted(.percent.precision(.fractionLength(1)))
}
func nodeSizeLabel(_ node: DiskNode, metric: SizeMetric) -> String {
    if node.issueCount > 0 { return node.bytes(metric) > 0 ? "已读 \(formattedBytes(node.bytes(metric)))" : "未读取" }
    return formattedBytes(node.bytes(metric))
}

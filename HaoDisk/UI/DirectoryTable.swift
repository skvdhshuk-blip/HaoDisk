import AppKit
import SwiftUI

/// Finder-style selection, scrolling and keyboard behavior shared by both presentations.
struct DirectoryTable: NSViewRepresentable {
    @ObservedObject var model: DiskModel
    var detailed = false

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = BrowserTable()
        table.coordinator = context.coordinator
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openRow)
        table.menu = NSMenu()
        table.menu?.delegate = context.coordinator
        for (id, title, width) in [("name", "名称", 230.0), ("size", "大小", 94.0), ("share", "占比", 72.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 130 : width
            column.maxWidth = id == "name" ? 2000 : width
            if id != "share" { column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "name") }
            table.addTableColumn(column)
        }
        table.setAccessibilityLabel("目录内容")
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? BrowserTable else { return }
        let coordinator = context.coordinator
        coordinator.model = model
        table.tableColumns.last?.isHidden = !detailed
        table.isEnabledForInput = !model.isBrowsingBusy
        table.alphaValue = model.isScanning ? 0.55 : 1
        // Snapshot/directory/metric/sort form the data identity; selection is O(1).
        if coordinator.display?.presentation.key != model.presentation?.key {
            coordinator.display = model.display
            coordinator.updating = true
            table.reloadData()
            coordinator.updating = false
        }
        let descriptor = NSSortDescriptor(key: model.sort.byName ? "name" : "size", ascending: model.sort.ascending)
        if table.sortDescriptors != [descriptor] {
            coordinator.updating = true
            table.sortDescriptors = [descriptor]
            coordinator.updating = false
        }
        let selected = model.selectedID.flatMap { model.presentation?.rowByID[$0] } ?? -1
        if table.selectedRow != selected {
            coordinator.updating = true
            table.selectRowIndexes(selected < 0 ? [] : IndexSet(integer: selected), byExtendingSelection: false)
            if selected >= 0 { table.scrollRowToVisible(selected) }
            coordinator.updating = false
        }
        // Only queue changes need to repaint the visible status icons.
        if coordinator.basket != model.basket {
            coordinator.basket = model.basket
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                for row in visible.location..<min(table.numberOfRows, visible.upperBound) {
                    if let node = coordinator.node(at: row),
                       let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NameCell {
                        cell.status.image = coordinator.statusImage(node)
                        cell.status.setAccessibilityElement(cell.status.image != nil)
                    }
                }
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {
        var model: DiskModel
        weak var table: NSTableView?
        var display: DirectoryDisplay?
        var basket: Set<Int> = []
        private let folderIcon = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        private let fileIcon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        private let linkIcon = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        private let queuedIcon = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "已加入清单")
        private let issueIcon = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "未完整读取")
        var updating = false
        init(model: DiskModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { display?.presentation.rowIDs.count ?? 0 }
        func node(at row: Int) -> DiskNode? {
            guard let display, display.presentation.rowIDs.indices.contains(row) else { return nil }
            return display.snapshot.nodes[display.presentation.rowIDs[row]]
        }

        func statusImage(_ node: DiskNode) -> NSImage? {
            model.basket.contains(node.id) ? queuedIcon : node.issueCount > 0 ? issueIcon : nil
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let node = node(at: row), let display, let column = tableColumn else { return nil }
            if column.identifier.rawValue == "name" {
                let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NameCell ?? NameCell()
                cell.identifier = column.identifier
                cell.label.stringValue = node.name
                cell.icon.image = node.identity.isLink ? linkIcon : node.isDirectory ? folderIcon : fileIcon
                cell.icon.contentTintColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
                cell.status.image = statusImage(node)
                cell.status.setAccessibilityElement(cell.status.image != nil)
                cell.icon.setAccessibilityElement(false)
                cell.toolTip = node.url.path
                cell.setAccessibilityLabel(node.name)
                return cell
            }
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = column.identifier
            if cell.textField == nil {
                let field = NSTextField(labelWithString: "")
                field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                field.alignment = .right
                field.textColor = .secondaryLabelColor
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field); cell.textField = field
                NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            cell.textField?.stringValue = column.identifier.rawValue == "size" ? nodeSizeLabel(node, metric: display.presentation.key.metric) : node.issueCount > 0 ? "—" : percentage(node.bytes(display.presentation.key.metric), total: display.snapshot.nodes[display.presentation.key.directoryID].bytes(display.presentation.key.metric))
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, !model.isBrowsingBusy else { return }
            model.selectedID = node(at: table.selectedRow)?.id
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !model.isBrowsingBusy }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let descriptor = tableView.sortDescriptors.first else { return }
            model.sort = descriptor.key == "name" ? (descriptor.ascending ? .nameAscending : .nameDescending) : (descriptor.ascending ? .sizeAscending : .sizeDescending)
        }
        @objc func openRow() { model.openSelected() }
        @objc func reveal() { if let node = model.selected { model.reveal(node) } }
        @objc func inspect() { model.showInspector = true }
        @objc func toggleQueue() {
            guard let node = model.selected else { return }
            if model.basket.contains(node.id) { model.basket.remove(node.id) } else { model.add(node) }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard !model.isBrowsingBusy, let table, let node = node(at: table.clickedRow) else { return }
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            func item(_ title: String, _ action: Selector, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.isEnabled = enabled; menu.addItem(item)
            }
            menu.autoenablesItems = false
            if node.canNavigate { item("打开文件夹", #selector(openRow)) }
            item("显示简介", #selector(inspect))
            item("在 Finder 中显示", #selector(reveal))
            menu.addItem(.separator())
            item(model.basket.contains(node.id) ? "从待清理移除" : "加入待清理", #selector(toggleQueue), enabled: model.selectedCleanupReason == nil)
        }
    }
}

private final class BrowserTable: NSTableView {
    weak var coordinator: DirectoryTable.Coordinator?
    var isEnabledForInput = true
    override func keyDown(with event: NSEvent) {
        guard isEnabledForInput else { return }
        switch event.keyCode {
        case 36, 124: coordinator?.model.openSelected()
        case 123: coordinator?.model.up()
        case 53: deselectAll(nil)
        default: super.keyDown(with: event)
        }
    }
}

private final class NameCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let icon = NSImageView()
    let status = NSImageView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.contentTintColor = .secondaryLabelColor
        for view in [icon, label, status] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5), status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), status.centerYAnchor.constraint(equalTo: centerYAnchor), status.widthAnchor.constraint(equalToConstant: 13), status.heightAnchor.constraint(equalToConstant: 13)
        ])
        textField = label
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

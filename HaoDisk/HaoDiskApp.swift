import SwiftUI

@main
struct HaoDiskApp: App {
    @StateObject private var model = DiskModel()

    var body: some Scene {
        Window("HaoDisk", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("选择文件夹…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
            }
            CommandMenu("分析") {
                Button("后退") { model.back() }.keyboardShortcut("[").disabled(!model.canGoBack || model.isBusy)
                Button("前进") { model.forward() }.keyboardShortcut("]").disabled(!model.canGoForward || model.isBusy)
                Button("打开所选项目") { model.openSelected() }.keyboardShortcut(.downArrow, modifiers: .command).disabled(model.selected == nil || model.isBrowsingBusy)
                Button("重新扫描") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy || !model.hasAccess)
                Button("返回上层") { model.up() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.currentID == 0 || model.isBusy)
                Button("停止扫描") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
                Divider()
                Button("面积图") { model.visualMode = true }.keyboardShortcut("1")
                Button("列表") { model.visualMode = false }.keyboardShortcut("2")
                Button("显示简介") { model.showInspector.toggle() }.keyboardShortcut("i").disabled(model.selected == nil || model.isBrowsingBusy)
                Button("清理所选项目…") { model.reviewSelected() }.keyboardShortcut(.delete, modifiers: .command).disabled(model.selected == nil || model.selectedCleanupReason != nil || model.isBrowsingBusy)
            }
        }
    }
}

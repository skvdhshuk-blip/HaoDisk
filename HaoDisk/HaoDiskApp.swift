import SwiftUI

@main
struct HaoDiskApp: App {
    @StateObject private var model = DiskModel()

    var body: some Scene {
        Window("HaoDisk", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 660)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("选择文件夹…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
            }
            CommandMenu("分析") {
                Button("重新扫描") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy || !model.hasAccess)
                Button("返回上层") { model.up() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.currentID == 0 || model.isBusy)
                Button("停止扫描") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
            }
        }
    }
}

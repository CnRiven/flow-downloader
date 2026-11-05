import AppKit
import SwiftUI
import FlowCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--screenshot"), let position = CommandLine.arguments.firstIndex(of: "--screenshot"), CommandLine.arguments.count > position + 1 {
            let output = CommandLine.arguments[position + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
                NSApp.terminate(nil)
            }
        }
    }
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.hasActiveProcesses == true {
            let alert = NSAlert()
            alert.messageText = "停止当前工作并退出？"
            alert.informativeText = "下载任务会保留；正在进行的组件安装会取消，下次打开后可以重试。"
            alert.addButton(withTitle: "暂停并退出"); alert.addButton(withTitle: "继续下载")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        model?.shutdown(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct FlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    @MainActor init() {
        if let root = AppSmokeRun.root {
            let bin = root.appendingPathComponent("engines/bin")
            _model = StateObject(wrappedValue: AppModel(managedDirectory: bin,
                locatePaths: { EnginePaths(managedDirectory: bin, searchDirectories: []) },
                storageDirectory: root.appendingPathComponent("app-data"),
                preferences: UserDefaults(suiteName: "app.flow.smoke." + UUID().uuidString)!))
        } else { _model = StateObject(wrappedValue: AppModel()) }
    }

    var body: some Scene {
        WindowGroup("拾流 · Flow") {
            ContentView().environmentObject(model)
                .onAppear { delegate.model = model }
                .task {
                    if AppSmokeRun.root != nil { await AppSmokeRun.run(model) }
                    else { model.startEnginePreparation() }
                }
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1150, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建下载") { model.showingNew = true }.keyboardShortcut("n")
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.showingSettings = true }.keyboardShortcut(",")
            }
        }
    }
}

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    OKRunLauncher.launchConfiguredAppIfNeeded()
    BackupAgentStore.shared.startScheduler()
    OKProxyClientStore.shared.startIfEnabled()
    OKRunLocalSwitchStore.shared.startIfEnabled()
    LocalAIStore.shared.startIfEnabled()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationWillTerminate(_ notification: Notification) {
    OKProxyClientStore.shared.stopForAppTermination()
    OKRunLocalSwitchStore.shared.stopForAppTermination()
    LocalAIStore.shared.stopForAppTermination()
  }
}

@main
struct OkBrainCCApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  init() {
    LocalAIHeadlessCLI.runAndExitIfRequested()
  }

  var body: some Scene {
    Window("OkBrainCC", id: WindowID.main) {
      ContentView()
        .frame(minWidth: 760, minHeight: 480)
    }
    .defaultSize(width: 900, height: 580)

    MenuBarExtra("OkBrainCC", systemImage: "brain.head.profile") {
      MenuBarView()
    }
  }
}

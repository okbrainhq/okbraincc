import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var isTerminating = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    OKRunLauncher.launchConfiguredAppIfNeeded()
    BackupAgentStore.shared.startScheduler()
    OKProxyClientStore.shared.startIfEnabled()
    OKRunLocalSwitchStore.shared.startIfEnabled()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !isTerminating else { return .terminateLater }
    isTerminating = true

    AppState.shared.isShuttingDown = true
    AppState.shared.shutdownMessage = "Stopping services…"
    ShutdownPanelController.shared.show(message: "Stopping services…")

    Task {
      await OKProxyClientStore.shared.stopForAppTermination()
      await OKRunLocalSwitchStore.shared.stopForAppTermination()
      ShutdownPanelController.shared.close()
      NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    return .terminateLater
  }
}

@main
struct OkBrainCCApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

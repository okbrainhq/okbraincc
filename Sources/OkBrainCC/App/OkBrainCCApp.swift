import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    OKRunLauncher.launchConfiguredAppIfNeeded()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
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

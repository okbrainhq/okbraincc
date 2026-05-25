import AppKit
import SwiftUI

struct MenuBarView: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Open Window") {
      openWindow(id: WindowID.main)
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }

    Divider()

    Button("Quit OkBrainCC") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}

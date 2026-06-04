import AppKit
import SwiftUI

@MainActor
final class ShutdownPanelController {
  static let shared = ShutdownPanelController()
  private var panel: NSPanel?

  private init() {}

  func show(message: String) {
    if panel != nil { return }

    let contentView = NSHostingController(rootView: ShutdownPanelView(message: message))
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
      styleMask: [.utilityWindow, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .modalPanel
    panel.title = "OkBrainCC"
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.contentViewController = contentView

    if let screen = NSScreen.main ?? NSScreen.screens.first {
      let screenFrame = screen.visibleFrame
      let x = screenFrame.midX - 180
      let y = screenFrame.midY - 80
      panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    panel.makeKeyAndOrderFront(nil)
    panel.orderFrontRegardless()

    self.panel = panel
  }

  func close() {
    panel?.close()
    panel = nil
  }
}

struct ShutdownPanelView: View {
  let message: String

  var body: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.2)
        .controlSize(.regular)

      Text(message)
        .font(.headline)
        .multilineTextAlignment(.center)

      Text("Please wait while services stop.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(width: 360, height: 160)
  }
}

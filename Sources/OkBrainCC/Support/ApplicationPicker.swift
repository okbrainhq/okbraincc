import AppKit
import Foundation
import UniformTypeIdentifiers

enum ApplicationPicker {
  static func chooseApplication(startingAt currentURL: URL) -> URL? {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = currentURL.deletingLastPathComponent()
    panel.message = "Choose the OkrunVM application."
    panel.prompt = "Choose"

    guard panel.runModal() == .OK else {
      return nil
    }

    return panel.url
  }
}

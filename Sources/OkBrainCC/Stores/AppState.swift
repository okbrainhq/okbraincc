import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
  static let shared = AppState()

  @Published var isShuttingDown = false
  @Published var shutdownMessage = "Shutting down…"

  private init() {}
}

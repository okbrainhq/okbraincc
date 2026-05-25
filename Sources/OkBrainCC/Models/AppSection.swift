import Foundation

enum AppSection: String, CaseIterable, Hashable, Identifiable {
  case overview
  case workspace
  case integrations

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .overview:
      "Overview"
    case .workspace:
      "Workspace"
    case .integrations:
      "Integrations"
    }
  }

  var systemImage: String {
    switch self {
    case .overview:
      "rectangle.grid.2x2"
    case .workspace:
      "tray.full"
    case .integrations:
      "point.3.connected.trianglepath.dotted"
    }
  }

  var summary: String {
    switch self {
    case .overview:
      "A calm starting surface for the app shell."
    case .workspace:
      "A future home for local project state and tools."
    case .integrations:
      "A future home for connected services and actions."
    }
  }
}

import Foundation

enum AppSection: String, CaseIterable, Hashable, Identifiable {
  case startOKRun

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .startOKRun:
      "Start OKRun"
    }
  }

  var systemImage: String {
    switch self {
    case .startOKRun:
      "play.circle"
    }
  }
}

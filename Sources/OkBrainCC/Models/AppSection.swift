import Foundation

enum AppSection: String, CaseIterable, Hashable, Identifiable {
  case startOKRun
  case backupProdbox
  case backupSandbox

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .startOKRun:
      "Start OKRun"
    case .backupProdbox:
      "Backup: Prodbox"
    case .backupSandbox:
      "Backup: Sandbox"
    }
  }

  var systemImage: String {
    switch self {
    case .startOKRun:
      "play.circle"
    case .backupProdbox:
      "externaldrive"
    case .backupSandbox:
      "shippingbox"
    }
  }
}

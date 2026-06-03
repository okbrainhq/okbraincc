import Foundation

enum AppSection: String, CaseIterable, Hashable, Identifiable {
  case startOKRun
  case okProxyClient
  case backupProdbox
  case backupSandbox

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .startOKRun:
      "Start OKRun"
    case .okProxyClient:
      "OKProxy Client"
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
    case .okProxyClient:
      "network"
    case .backupProdbox:
      "externaldrive"
    case .backupSandbox:
      "shippingbox"
    }
  }
}

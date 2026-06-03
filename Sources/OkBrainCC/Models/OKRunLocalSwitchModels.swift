import Foundation

struct OKRunLocalSwitchSettings: Codable, Hashable {
  var host: String
  var port: String
  var statusPort: String

  static let repoURL = "https://github.com/okbrainhq/okrun.git"
  static let sourceURL = "https://github.com/okbrainhq/okrun/tree/main/web-switch"

  static let installURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("okrun-switch", isDirectory: true)

  static var webSwitchURL: URL {
    installURL.appendingPathComponent("web-switch", isDirectory: true)
  }

  static let localNodeURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/bin/node", isDirectory: false)

  static let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".okrun-switch/logs/local-switch.log", isDirectory: false)

  static let defaults = OKRunLocalSwitchSettings(
    host: "127.0.0.1",
    port: "9444",
    statusPort: "8080"
  )

  var trimmedHost: String {
    host.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedPort: String {
    port.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedStatusPort: String {
    statusPort.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var localPortValue: Int? {
    Self.validPort(from: trimmedPort)
  }

  var statusPortValue: Int? {
    Self.validPort(from: trimmedStatusPort)
  }

  var hasRequiredRuntimeFields: Bool {
    missingRequiredFieldNames.isEmpty
  }

  var missingRequiredFieldNames: [String] {
    var names: [String] = []
    if trimmedHost.isEmpty {
      names.append("host")
    }
    if localPortValue == nil {
      names.append("port (1-65535)")
    }
    if statusPortValue == nil {
      names.append("status port (1-65535)")
    }
    return names
  }

  private static func validPort(from value: String) -> Int? {
    guard let port = Int(value), (1...65_535).contains(port) else {
      return nil
    }
    return port
  }
}

struct OKRunLocalSwitchNodeStatus: Equatable {
  enum State: Equatable {
    case available
    case missing
    case unsupported
  }

  let state: State
  let path: String?
  let version: String?
  let message: String

  var isUsable: Bool {
    state == .available
  }

  var title: String {
    switch state {
    case .available:
      "Node.js Ready"
    case .missing:
      "Node.js Missing"
    case .unsupported:
      "Node.js Update Required"
    }
  }

  var systemImage: String {
    switch state {
    case .available:
      "checkmark.circle.fill"
    case .missing, .unsupported:
      "exclamationmark.triangle.fill"
    }
  }

  static func available(path: String, version: String) -> OKRunLocalSwitchNodeStatus {
    OKRunLocalSwitchNodeStatus(
      state: .available,
      path: path,
      version: version,
      message: "Using \(version) at \(path)"
    )
  }

  static let missing = OKRunLocalSwitchNodeStatus(
    state: .missing,
    path: nil,
    version: nil,
    message: "Node.js 20+ is required before configuring OKRun Local Switch."
  )

  static func unsupported(path: String, version: String) -> OKRunLocalSwitchNodeStatus {
    OKRunLocalSwitchNodeStatus(
      state: .unsupported,
      path: path,
      version: version,
      message: "Found \(version) at \(path). OKRun Local Switch requires Node.js 20+."
    )
  }
}

enum OKRunLocalSwitchCommandError: LocalizedError {
  case missingNode
  case missingRepository(String)
  case missingRequiredSettings([String])
  case missingEntrypoint(String)
  case launchFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingNode:
      "Install Node.js 20+ before continuing."
    case .missingRepository(let path):
      "OKRun repository was not found at \(path)."
    case .missingRequiredSettings(let names):
      "Set \(names.joined(separator: ", ")) before starting OKRun Local Switch."
    case .missingEntrypoint(let path):
      "OKRun Local Switch entrypoint was not found at \(path)."
    case .launchFailed(let message):
      message
    }
  }
}

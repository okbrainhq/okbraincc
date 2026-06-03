import Foundation

struct OKProxySettings: Codable, Hashable {
  var serverHost: String
  var targetHost: String
  var clientCertPath: String
  var clientKeyPath: String
  var caCertPath: String

  static let repoURL = "https://github.com/okbrainhq/okproxy"

  static let installURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("okproxy", isDirectory: true)

  static let localNodeURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/bin/node", isDirectory: false)

  static let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".okproxy/logs/client.log", isDirectory: false)

  static let defaults = OKProxySettings(
    serverHost: "",
    targetHost: "localhost:3000",
    clientCertPath: "",
    clientKeyPath: "",
    caCertPath: ""
  )

  var trimmedServerHost: String {
    serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedTargetHost: String {
    targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedClientCertPath: String {
    clientCertPath.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedClientKeyPath: String {
    clientKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedCACertPath: String {
    caCertPath.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var hasRequiredRuntimeFields: Bool {
    missingRequiredFieldNames.isEmpty
  }

  var missingRequiredFieldNames: [String] {
    var names: [String] = []
    if trimmedServerHost.isEmpty {
      names.append("server host")
    }
    if trimmedTargetHost.isEmpty {
      names.append("target host")
    }
    if trimmedClientCertPath.isEmpty {
      names.append("client certificate")
    }
    if trimmedClientKeyPath.isEmpty {
      names.append("client private key")
    }
    if trimmedCACertPath.isEmpty {
      names.append("CA certificate")
    }
    return names
  }
}

struct OKProxyNodeStatus: Equatable {
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

  static func available(path: String, version: String) -> OKProxyNodeStatus {
    OKProxyNodeStatus(
      state: .available,
      path: path,
      version: version,
      message: "Using \(version) at \(path)"
    )
  }

  static let missing = OKProxyNodeStatus(
    state: .missing,
    path: nil,
    version: nil,
    message: "Node.js 20+ is required before configuring OKProxy."
  )

  static func unsupported(path: String, version: String) -> OKProxyNodeStatus {
    OKProxyNodeStatus(
      state: .unsupported,
      path: path,
      version: version,
      message: "Found \(version) at \(path). OKProxy requires Node.js 20+."
    )
  }
}

struct OKProxyCommandResult: Hashable {
  let exitCode: Int32
  let output: String
}

enum OKProxyClientStatus: Equatable {
  case disabled
  case stopped
  case starting
  case running
  case stopping
  case busy(String)
  case failed(String)

  var title: String {
    switch self {
    case .disabled:
      "Disabled"
    case .stopped:
      "Stopped"
    case .starting:
      "Starting"
    case .running:
      "Running"
    case .stopping:
      "Stopping"
    case .busy(let title):
      title
    case .failed:
      "Failed"
    }
  }

  var detail: String? {
    switch self {
    case .failed(let message):
      message
    default:
      nil
    }
  }

  var systemImage: String {
    switch self {
    case .disabled:
      "power.circle"
    case .stopped:
      "stop.circle"
    case .starting, .busy:
      "clock.arrow.circlepath"
    case .running:
      "checkmark.circle.fill"
    case .stopping:
      "stop.circle.fill"
    case .failed:
      "exclamationmark.triangle.fill"
    }
  }

  var isRunning: Bool {
    if case .running = self {
      return true
    }
    return false
  }
}

enum OKProxyCommandError: LocalizedError {
  case missingNode
  case missingRepository(String)
  case missingRequiredSettings([String])
  case missingFile(String)
  case launchFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingNode:
      "Install Node.js 20+ before continuing."
    case .missingRepository(let path):
      "OKProxy repository was not found at \(path)."
    case .missingRequiredSettings(let names):
      "Set \(names.joined(separator: ", ")) before starting OKProxy."
    case .missingFile(let path):
      "Required file was not found: \(path)."
    case .launchFailed(let message):
      message
    }
  }
}

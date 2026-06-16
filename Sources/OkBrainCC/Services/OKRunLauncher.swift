import AppKit
import Foundation

enum OKRunLauncher {
  static let appPathKey = "okrunAppPath"
  static let autorunEnabledKey = "okrunAutorunEnabled"

  static var defaultAutorunEnabled: Bool {
    AppEnvironment.current.isProduction
  }

  static var defaultAppURL: URL {
    let suffix = AppEnvironment.current.stateDirectorySuffix
    return URL(fileURLWithPath: "/Applications/OkrunVM\(suffix).app")
  }

  static func configuredAppURL(defaults: UserDefaults = AppEnvironment.userDefaults) -> URL {
    let configuredPath = defaults.string(forKey: appPathKey)
    return URL(fileURLWithPath: configuredPath ?? defaultAppURL.path)
  }

  static func isAutorunEnabled(defaults: UserDefaults = AppEnvironment.userDefaults) -> Bool {
    guard let configuredValue = defaults.object(forKey: autorunEnabledKey) as? Bool else {
      return defaultAutorunEnabled
    }

    return configuredValue
  }

  static func appExists(at url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  static func launchConfiguredAppIfNeeded() {
    guard isAutorunEnabled() else {
      return
    }

    launch(at: configuredAppURL()) { _ in }
  }

  static func launch(at url: URL, completion: @escaping (Result<Void, OKRunLaunchError>) -> Void) {
    guard appExists(at: url) else {
      completion(.failure(.missingApplication(url.path)))
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true

    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { runningApplication, error in
      DispatchQueue.main.async {
        if let error {
          completion(.failure(.launchFailed(error.localizedDescription)))
          return
        }

        guard runningApplication != nil else {
          completion(.failure(.launchFailed("macOS did not return a running app.")))
          return
        }

        completion(.success(()))
      }
    }
  }
}

enum OKRunLaunchError: LocalizedError {
  case missingApplication(String)
  case launchFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingApplication:
      "App not found"
    case .launchFailed(let message):
      message
    }
  }
}

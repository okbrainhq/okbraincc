import Foundation

/// Detects and exposes the current app environment (development vs production).
///
/// Dev/prod isolation is enforced through:
/// - separate UserDefaults suites
/// - separate on-disk state directories (suffixed with `-dev`)
/// - separate NODE_ENV values passed to Node-based services
/// - separate bundle IDs chosen at build time
enum AppEnvironment: String, Sendable {
  case development = "dev"
  case production = "prod"

  /// Resolved once per launch. Precedence:
  /// 1. `--dev` / `--prod` launch arguments
  /// 2. `OKBRAINCC_ENV` environment variable (`dev`/`development` or `prod`/`production`)
  /// 3. `AppEnvironment` value in `Info.plist`
  /// 4. Defaults to `.production` for safety
  static let current: AppEnvironment = {
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("--dev") {
      return .development
    }
    if arguments.contains("--prod") {
      return .production
    }

    if let env = ProcessInfo.processInfo.environment["OKBRAINCC_ENV"]?.lowercased() {
      switch env {
      case "dev", "development":
        return .development
      case "prod", "production":
        return .production
      default:
        break
      }
    }

    if let plistValue = Bundle.main.object(forInfoDictionaryKey: "AppEnvironment") as? String {
      switch plistValue.lowercased() {
      case "dev", "development":
        return .development
      case "prod", "production":
        return .production
      default:
        break
      }
    }

    return .production
  }()

  var isDevelopment: Bool { self == .development }
  var isProduction: Bool { self == .production }

  var displayName: String {
    switch self {
    case .development:
      return "Dev"
    case .production:
      return "Prod"
    }
  }

  /// Suffix appended to on-disk state directories in development mode.
  var stateDirectorySuffix: String {
    switch self {
    case .development:
      return "-dev"
    case .production:
      return ""
    }
  }

  /// `NODE_ENV` value passed to Node-based services.
  var nodeEnvironment: String {
    switch self {
    case .development:
      return "development"
    case .production:
      return "production"
    }
  }

  /// The UserDefaults suite used for this environment.
  ///
  /// Production keeps using `UserDefaults.standard` so existing installed users
  /// keep their settings. Development uses a separate suite so local builds
  /// never overwrite production settings.
  static var userDefaults: UserDefaults {
    if let suiteName = current.userDefaultsSuiteName,
       let suite = UserDefaults(suiteName: suiteName) {
      return suite
    }
    return .standard
  }

  private var userDefaultsSuiteName: String? {
    switch self {
    case .development:
      return "com.okbraincc.app.dev"
    case .production:
      return nil
    }
  }
}

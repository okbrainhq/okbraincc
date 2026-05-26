import Foundation

struct BackupScriptResult: Hashable {
  let exitCode: Int32
  let output: String
}

enum BackupScriptError: LocalizedError {
  case missingScriptsDirectory
  case missingScript(String)
  case launchFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingScriptsDirectory:
      "Backup scripts directory was not found in the app bundle."
    case .missingScript(let name):
      "Backup script was not found: \(name)"
    case .launchFailed(let message):
      message
    }
  }
}

enum BackupScriptRunner {
  static func scriptURL(named name: String) throws -> URL {
    for directory in candidateScriptDirectories() {
      let url = directory.appendingPathComponent(name, isDirectory: false)
      if FileManager.default.fileExists(atPath: url.path) {
        return url
      }
    }

    throw BackupScriptError.missingScript(name)
  }

  static func run(
    scriptName: String,
    arguments: [String],
    extraEnvironment: [String: String] = [:],
    onProcessStart: @escaping (Process) -> Void,
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> BackupScriptResult {
    let scriptURL = try scriptURL(named: scriptName)

    return try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = [scriptURL.path] + arguments
      process.currentDirectoryURL = scriptURL.deletingLastPathComponent()

      var environment = ProcessInfo.processInfo.environment
      environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      environment["OKBRAINCC_BACKUP_AGENT"] = "1"
      for (key, value) in extraEnvironment {
        environment[key] = value
      }
      process.environment = environment

      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe

      let capture = ProtectedString()

      pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else {
          return
        }

        let text = String(decoding: data, as: UTF8.self)
        capture.append(text)
        onOutput(text)
      }

      process.terminationHandler = { process in
        pipe.fileHandleForReading.readabilityHandler = nil
        let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingData.isEmpty {
          let text = String(decoding: remainingData, as: UTF8.self)
          capture.append(text)
          onOutput(text)
        }

        continuation.resume(
          returning: BackupScriptResult(
            exitCode: process.terminationStatus,
            output: capture.value
          )
        )
      }

      do {
        try process.run()
        onProcessStart(process)
      } catch {
        pipe.fileHandleForReading.readabilityHandler = nil
        continuation.resume(throwing: BackupScriptError.launchFailed(error.localizedDescription))
      }
    }
  }

  private static func candidateScriptDirectories() -> [URL] {
    var directories: [URL] = []

    if let mainResourceURL = Bundle.main.resourceURL {
      directories.append(mainResourceURL.appendingPathComponent("BackupAgent", isDirectory: true))
      directories.append(mainResourceURL.appendingPathComponent("Resources/BackupAgent", isDirectory: true))
    }

    if let moduleResourceURL = Bundle.module.resourceURL {
      directories.append(moduleResourceURL.appendingPathComponent("BackupAgent", isDirectory: true))
      directories.append(moduleResourceURL.appendingPathComponent("Resources/BackupAgent", isDirectory: true))
    }

    return directories
  }
}

private final class ProtectedString: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = ""
  private let maximumLength = 120_000

  var value: String {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ text: String) {
    lock.lock()
    storage.append(text)
    if storage.count > maximumLength {
      storage.removeFirst(storage.count - maximumLength)
    }
    lock.unlock()
  }
}

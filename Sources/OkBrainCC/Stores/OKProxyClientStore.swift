import AppKit
import Foundation

@MainActor
final class OKProxyClientStore: ObservableObject {
  static let shared = OKProxyClientStore()

  @Published private(set) var settings: OKProxySettings
  @Published private(set) var isEnabled: Bool
  @Published private(set) var status: OKProxyClientStatus
  @Published private(set) var nodeStatus: OKProxyNodeStatus
  @Published private(set) var isInstalled = false
  @Published private(set) var isBusy = false
  @Published private(set) var latestLogLines = ""
  @Published private(set) var lastOperationOutput = ""

  private let defaults = UserDefaults.standard
  private var process: Process?
  private var stopWasRequested = false
  private var logRefreshTimer: Timer?

  private init() {
    let loadedSettings = Self.loadSettings(defaults: defaults)
    let loadedIsEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
    let detectedNodeStatus = Self.detectNodeStatus()

    settings = loadedSettings
    isEnabled = loadedIsEnabled
    nodeStatus = detectedNodeStatus
    status = loadedIsEnabled ? .stopped : .disabled
    refreshInstallationStatus()
    refreshLogs()
    startLogRefreshTimer()
  }

  var isClientRunning: Bool {
    process?.isRunning == true
  }

  var logURL: URL {
    OKProxySettings.logURL
  }

  var canConfigure: Bool {
    nodeStatus.isUsable && isInstalled
  }

  var canRun: Bool {
    canConfigure && settings.hasRequiredRuntimeFields
  }

  func startIfEnabled() {
    guard isEnabled else {
      status = .disabled
      return
    }

    startClient()
  }

  func refreshNodeStatus() {
    nodeStatus = Self.detectNodeStatus()
  }

  func updateSettings(_ newSettings: OKProxySettings) {
    settings = newSettings
    persistSettings()
  }

  func setEnabled(_ enabled: Bool) {
    if enabled {
      refreshNodeStatus()
      refreshInstallationStatus()

      guard nodeStatus.isUsable else {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        status = .failed(OKProxyCommandError.missingNode.localizedDescription)
        return
      }

      guard isInstalled else {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        status = .failed("Download and set up OKProxy first.")
        return
      }

      guard settings.hasRequiredRuntimeFields else {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        status = .failed(OKProxyCommandError.missingRequiredSettings(settings.missingRequiredFieldNames).localizedDescription)
        return
      }

      defaults.set(true, forKey: Self.enabledKey)
      isEnabled = true
      startClient()
    } else {
      defaults.set(false, forKey: Self.enabledKey)
      isEnabled = false
      stopClient()
    }
  }

  func installNodeJS() {
    runNodeJSInstall(forceUpdate: false)
  }

  func updateNodeJS() {
    runNodeJSInstall(forceUpdate: true)
  }

  private func runNodeJSInstall(forceUpdate: Bool) {
    guard !isBusy else {
      return
    }

    let action = forceUpdate ? "update" : "install"
    let title = forceUpdate ? "Updating Node.js" : "Installing Node.js"

    if isClientRunning {
      appendOperationOutput("[OKProxy] Stop the client before Node.js \(action).\n")
      return
    }

    isBusy = true
    status = .busy(title)
    lastOperationOutput = "[\(Self.timestampFormatter.string(from: Date()))] \(title)...\n"

    Task { @MainActor in
      do {
        let result = try await OKProxyCommandRunner.installNodeJS(forceUpdate: forceUpdate) { [weak self] text in
          Task { @MainActor in
            self?.appendOperationOutput(text)
          }
        }

        isBusy = false
        refreshNodeStatus()
        appendOperationOutput("[OKProxy] Node.js \(action) finished with exit code \(result.exitCode).\n")

        if result.exitCode == 0, nodeStatus.isUsable {
          status = isEnabled ? .stopped : .disabled
        } else {
          status = .failed("Node.js \(action) exited with code \(result.exitCode).")
        }
      } catch {
        isBusy = false
        refreshNodeStatus()
        status = .failed(error.localizedDescription)
        appendOperationOutput("[OKProxy] Node.js \(action) failed: \(error.localizedDescription)\n")
      }
    }
  }

  func downloadAndSetup() {
    guard !isBusy else {
      return
    }

    if isClientRunning {
      appendOperationOutput("[OKProxy] Stop the client before setup.\n")
      return
    }

    refreshNodeStatus()
    guard nodeStatus.isUsable else {
      status = .failed(OKProxyCommandError.missingNode.localizedDescription)
      appendOperationOutput("[OKProxy] \(OKProxyCommandError.missingNode.localizedDescription)\n")
      return
    }

    isBusy = true
    status = .busy("Setting up OKProxy")
    lastOperationOutput = "[\(Self.timestampFormatter.string(from: Date()))] Setting up OKProxy...\n"

    Task { @MainActor in
      do {
        let result = try await OKProxyCommandRunner.downloadAndSetup { [weak self] text in
          Task { @MainActor in
            self?.appendOperationOutput(text)
          }
        }

        isBusy = false
        refreshInstallationStatus()
        appendOperationOutput("[OKProxy] Setup finished with exit code \(result.exitCode).\n")

        if result.exitCode == 0 {
          status = isEnabled ? .stopped : .disabled
          if isEnabled, settings.hasRequiredRuntimeFields {
            startClient()
          }
        } else {
          status = .failed("Setup exited with code \(result.exitCode).")
        }
      } catch {
        isBusy = false
        refreshInstallationStatus()
        status = .failed(error.localizedDescription)
        appendOperationOutput("[OKProxy] Setup failed: \(error.localizedDescription)\n")
      }
    }
  }

  func updateOKProxy() {
    guard !isBusy else {
      return
    }

    if isClientRunning {
      appendOperationOutput("[OKProxy] Stop the client before updating.\n")
      return
    }

    refreshNodeStatus()
    guard nodeStatus.isUsable else {
      status = .failed(OKProxyCommandError.missingNode.localizedDescription)
      appendOperationOutput("[OKProxy] \(OKProxyCommandError.missingNode.localizedDescription)\n")
      return
    }

    isBusy = true
    status = .busy("Updating OKProxy")
    lastOperationOutput = "[\(Self.timestampFormatter.string(from: Date()))] Updating OKProxy...\n"

    Task { @MainActor in
      do {
        let result = try await OKProxyCommandRunner.update { [weak self] text in
          Task { @MainActor in
            self?.appendOperationOutput(text)
          }
        }

        isBusy = false
        refreshInstallationStatus()
        appendOperationOutput("[OKProxy] Update finished with exit code \(result.exitCode).\n")

        if result.exitCode == 0 {
          status = isEnabled ? .stopped : .disabled
          if isEnabled, settings.hasRequiredRuntimeFields {
            startClient()
          }
        } else {
          status = .failed("Update exited with code \(result.exitCode).")
        }
      } catch {
        isBusy = false
        refreshInstallationStatus()
        status = .failed(error.localizedDescription)
        appendOperationOutput("[OKProxy] Update failed: \(error.localizedDescription)\n")
      }
    }
  }

  func startClient() {
    guard !isBusy else {
      return
    }

    guard process?.isRunning != true else {
      status = .running
      return
    }

    refreshNodeStatus()
    refreshInstallationStatus()

    guard nodeStatus.isUsable else {
      status = .failed(OKProxyCommandError.missingNode.localizedDescription)
      return
    }

    guard isInstalled else {
      status = .failed("OKProxy is not installed at \(OKProxySettings.installURL.path).")
      return
    }

    guard settings.hasRequiredRuntimeFields else {
      status = .failed(OKProxyCommandError.missingRequiredSettings(settings.missingRequiredFieldNames).localizedDescription)
      return
    }

    let clientCertPath = Self.expandedPath(settings.trimmedClientCertPath)
    let clientKeyPath = Self.expandedPath(settings.trimmedClientKeyPath)
    let caCertPath = Self.expandedPath(settings.trimmedCACertPath)

    for path in [clientCertPath, clientKeyPath, caCertPath] where !FileManager.default.fileExists(atPath: path) {
      status = .failed(OKProxyCommandError.missingFile(path).localizedDescription)
      return
    }

    let clientURL = OKProxySettings.installURL.appendingPathComponent("apps/client/index.js", isDirectory: false)
    guard FileManager.default.fileExists(atPath: clientURL.path) else {
      status = .failed("OKProxy client entrypoint was not found at \(clientURL.path).")
      return
    }

    let nodePath = nodeStatus.path ?? OKProxySettings.localNodeURL.path
    let command = [
      OKProxyCommandRunner.shellQuote(nodePath),
      OKProxyCommandRunner.shellQuote(clientURL.path),
      "--multipath",
      "--server",
      OKProxyCommandRunner.shellQuote(settings.trimmedServerHost),
      "--target",
      OKProxyCommandRunner.shellQuote(settings.trimmedTargetHost),
      "--cert",
      OKProxyCommandRunner.shellQuote(clientCertPath),
      "--key",
      OKProxyCommandRunner.shellQuote(clientKeyPath),
      "--ca",
      OKProxyCommandRunner.shellQuote(caCertPath)
    ].joined(separator: " ")

    appendToLog("\n[\(Self.timestampFormatter.string(from: Date()))] Starting OKProxy: \(command)\n")
    stopWasRequested = false
    status = .starting

    let clientProcess = Process()
    clientProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
    clientProcess.arguments = ["-lc", command]
    clientProcess.currentDirectoryURL = OKProxySettings.installURL.appendingPathComponent("apps/client", isDirectory: true)

    var environment = ProcessInfo.processInfo.environment
    let localBinPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/bin", isDirectory: true)
      .path
    environment["PATH"] = "\(localBinPath):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    environment["NODE_ENV"] = "production"
    environment["MULTIPATH_ENABLED"] = "true"
    clientProcess.environment = environment

    let pipe = Pipe()
    clientProcess.standardOutput = pipe
    clientProcess.standardError = pipe

    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        return
      }

      let text = String(decoding: data, as: UTF8.self)
      Task { @MainActor in
        self?.appendToLog(text)
      }
    }

    clientProcess.terminationHandler = { [weak self] process in
      pipe.fileHandleForReading.readabilityHandler = nil
      let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
      let remainingText = String(decoding: remainingData, as: UTF8.self)

      Task { @MainActor in
        if !remainingText.isEmpty {
          self?.appendToLog(remainingText)
        }
        self?.handleClientTermination(process.terminationStatus)
      }
    }

    do {
      try clientProcess.run()
      process = clientProcess
      status = .running
    } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      status = .failed(error.localizedDescription)
      appendToLog("[\(Self.timestampFormatter.string(from: Date()))] Failed to start OKProxy: \(error.localizedDescription)\n")
    }
  }

  func stopClient() {
    guard let process, process.isRunning else {
      status = isEnabled ? .stopped : .disabled
      return
    }

    status = .stopping
    stopWasRequested = true
    appendToLog("\n[\(Self.timestampFormatter.string(from: Date()))] Stop requested\n")
    process.terminate()
  }

  func refreshLogs() {
    latestLogLines = Self.tailLines(of: logURL, limit: 100)
  }

  func openInstallDirectory() {
    if FileManager.default.fileExists(atPath: OKProxySettings.installURL.path) {
      NSWorkspace.shared.open(OKProxySettings.installURL)
      return
    }

    let parentURL = OKProxySettings.installURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
    NSWorkspace.shared.open(parentURL)
  }

  func openLogDirectory() {
    let directoryURL = logURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    NSWorkspace.shared.open(directoryURL)
  }

  func refreshInstallationStatus() {
    isInstalled = Self.installationExists(at: OKProxySettings.installURL)
  }

  private func handleClientTermination(_ exitCode: Int32) {
    appendToLog("[\(Self.timestampFormatter.string(from: Date()))] OKProxy exited with code \(exitCode)\n")
    let wasStopRequested = stopWasRequested
    stopWasRequested = false
    process = nil
    refreshLogs()

    if isEnabled {
      status = (wasStopRequested || exitCode == 0) ? .stopped : .failed("OKProxy exited with code \(exitCode).")
    } else {
      status = .disabled
    }
  }

  private func appendToLog(_ text: String) {
    let directoryURL = logURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
      }

      let handle = try FileHandle(forWritingTo: logURL)
      defer {
        try? handle.close()
      }
      handle.seekToEndOfFile()
      if let data = text.data(using: .utf8) {
        handle.write(data)
      }
    } catch {
      latestLogLines = "Could not write log: \(error.localizedDescription)"
      return
    }

    refreshLogs()
  }

  private func appendOperationOutput(_ text: String) {
    lastOperationOutput.append(text)
    if lastOperationOutput.count > 120_000 {
      lastOperationOutput.removeFirst(lastOperationOutput.count - 120_000)
    }
  }

  private func persistSettings() {
    if let data = try? JSONEncoder().encode(settings) {
      defaults.set(data, forKey: Self.settingsKey)
    }
  }

  private func startLogRefreshTimer() {
    guard logRefreshTimer == nil else {
      return
    }

    let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refreshLogs()
      }
    }
    timer.tolerance = 0.5
    logRefreshTimer = timer
  }

  private static func loadSettings(defaults: UserDefaults) -> OKProxySettings {
    guard
      let data = defaults.data(forKey: settingsKey),
      let settings = try? JSONDecoder().decode(OKProxySettings.self, from: data)
    else {
      return .defaults
    }

    return settings
  }

  private static func installationExists(at url: URL) -> Bool {
    let gitURL = url.appendingPathComponent(".git", isDirectory: true)
    let clientURL = url.appendingPathComponent("apps/client/index.js", isDirectory: false)
    return FileManager.default.fileExists(atPath: gitURL.path)
      && FileManager.default.fileExists(atPath: clientURL.path)
  }

  private static func detectNodeStatus() -> OKProxyNodeStatus {
    let command = #"""
LOCAL_NODE="$HOME/.local/bin/node"
if [ -x "$LOCAL_NODE" ]; then
  printf '%s\n' "$LOCAL_NODE"
  "$LOCAL_NODE" -v
  exit 0
fi

NODE_PATH=$(command -v node 2>/dev/null || true)
if [ -n "$NODE_PATH" ]; then
  printf '%s\n' "$NODE_PATH"
  "$NODE_PATH" -v
  exit 0
fi

exit 1
"""#

    let result = runBlockingShell(command)
    guard result.exitCode == 0 else {
      return .missing
    }

    let lines = result.output
      .split(whereSeparator: { $0.isNewline })
      .map(String.init)

    guard lines.count >= 2 else {
      return .missing
    }

    let path = lines[0]
    let version = lines[1]
    guard let majorVersion = majorVersion(from: version), majorVersion >= 20 else {
      return .unsupported(path: path, version: version)
    }

    return .available(path: path, version: version)
  }

  private static func majorVersion(from version: String) -> Int? {
    var cleaned = version.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("v") {
      cleaned.removeFirst()
    }
    return cleaned.split(separator: ".").first.flatMap { Int($0) }
  }

  private static func runBlockingShell(_ command: String) -> (exitCode: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", command]

    var environment = ProcessInfo.processInfo.environment
    let localBinPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/bin", isDirectory: true)
      .path
    environment["PATH"] = "\(localBinPath):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    process.environment = environment

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
      try process.run()
    } catch {
      return (-1, error.localizedDescription)
    }

    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private static func expandedPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
  }

  private static func tailLines(of url: URL, limit: Int) -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return ""
    }

    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
      let maxBytes: UInt64 = 100_000
      let handle = try FileHandle(forReadingFrom: url)
      defer {
        try? handle.close()
      }

      if fileSize > maxBytes {
        try handle.seek(toOffset: fileSize - maxBytes)
      }

      let data = try handle.readToEnd() ?? Data()
      let text = String(decoding: data, as: UTF8.self)
      return text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .suffix(limit)
        .joined(separator: "\n")
    } catch {
      return "Could not read log: \(error.localizedDescription)"
    }
  }

  private static let settingsKey = "okproxy.client.settings.v2"
  private static let enabledKey = "okproxy.client.enabled"

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()
}

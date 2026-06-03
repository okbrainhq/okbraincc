import Foundation

enum OKRunLocalSwitchCommandRunner {
  static func installNodeJS(
    forceUpdate: Bool = false,
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> OKProxyCommandResult {
    try await OKProxyCommandRunner.installNodeJS(forceUpdate: forceUpdate, onOutput: onOutput)
  }

  static func downloadAndSetup(
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> OKProxyCommandResult {
    let installURL = OKRunLocalSwitchSettings.installURL
    let capture = OKProxyOutputCapture()
    let relay: @Sendable (String) -> Void = { text in
      capture.append(text)
      onOutput(text)
    }

    try FileManager.default.createDirectory(
      at: installURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    if FileManager.default.fileExists(atPath: installURL.appendingPathComponent(".git", isDirectory: true).path) {
      relay("[OKRun Local Switch] Repository already installed at \(installURL.path). Updating instead...\n")
      let result = try await update(onOutput: relay)
      return OKProxyCommandResult(exitCode: result.exitCode, output: capture.value)
    }

    if FileManager.default.fileExists(atPath: installURL.path) {
      let entries = (try? FileManager.default.contentsOfDirectory(atPath: installURL.path)) ?? []
      if entries.isEmpty {
        try FileManager.default.removeItem(at: installURL)
      } else {
        throw OKRunLocalSwitchCommandError.launchFailed(
          "A non-git directory already exists at \(installURL.path). Move it before setup."
        )
      }
    }

    relay("[OKRun Local Switch] Cloning \(OKRunLocalSwitchSettings.repoURL) into \(installURL.path)...\n")
    let cloneResult = try await OKProxyCommandRunner.runShell(
      "git clone \(OKProxyCommandRunner.shellQuote(OKRunLocalSwitchSettings.repoURL)) \(OKProxyCommandRunner.shellQuote(installURL.path))",
      currentDirectory: nil,
      onOutput: relay
    )
    if cloneResult.exitCode != 0 {
      return OKProxyCommandResult(exitCode: cloneResult.exitCode, output: capture.value)
    }

    let setupResult = try await runWebSwitchSetup(at: OKRunLocalSwitchSettings.webSwitchURL, onOutput: relay)
    return OKProxyCommandResult(exitCode: setupResult.exitCode, output: capture.value)
  }

  static func update(
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> OKProxyCommandResult {
    let installURL = OKRunLocalSwitchSettings.installURL
    guard FileManager.default.fileExists(atPath: installURL.appendingPathComponent(".git", isDirectory: true).path) else {
      throw OKRunLocalSwitchCommandError.missingRepository(installURL.path)
    }

    let capture = OKProxyOutputCapture()
    let relay: @Sendable (String) -> Void = { text in
      capture.append(text)
      onOutput(text)
    }

    relay("[OKRun Local Switch] Updating repository at \(installURL.path)...\n")
    let updateResult = try await OKProxyCommandRunner.runShell(
      "git fetch origin && git reset --hard origin/main",
      currentDirectory: installURL,
      onOutput: relay
    )
    if updateResult.exitCode != 0 {
      return OKProxyCommandResult(exitCode: updateResult.exitCode, output: capture.value)
    }

    let setupResult = try await runWebSwitchSetup(at: OKRunLocalSwitchSettings.webSwitchURL, onOutput: relay)
    return OKProxyCommandResult(exitCode: setupResult.exitCode, output: capture.value)
  }

  private static func runWebSwitchSetup(
    at webSwitchURL: URL,
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> OKProxyCommandResult {
    let packageJSONURL = webSwitchURL.appendingPathComponent("package.json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: packageJSONURL.path) else {
      throw OKRunLocalSwitchCommandError.missingEntrypoint(packageJSONURL.path)
    }

    onOutput("[OKRun Local Switch] Installing Node dependencies in web-switch...\n")
    return try await OKProxyCommandRunner.runShell(
      "npm install --omit=dev --no-audit --no-fund",
      currentDirectory: webSwitchURL,
      onOutput: onOutput
    )
  }
}

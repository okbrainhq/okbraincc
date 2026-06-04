import AppKit
import Foundation

@MainActor
final class LocalAIStore: ObservableObject {
  static let shared = LocalAIStore()

  @Published private(set) var settings: LocalAISettings
  @Published private(set) var isEnabled: Bool
  @Published private(set) var status: OKProxyClientStatus
  @Published private(set) var isBusy = false
  @Published private(set) var latestLogLines = ""
  @Published private(set) var lastOperationOutput = ""
  @Published private(set) var chatMessages: [LocalAIChatTurn] = []
  @Published private(set) var modelDownloadProgress = LocalAIModelDownloadProgress.idle

  private let defaults = UserDefaults.standard
  private var server: LocalOpenAIServer?

  private init() {
    let loadedSettings = Self.loadSettings(defaults: defaults)
    let loadedIsEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
    settings = loadedSettings
    isEnabled = loadedIsEnabled
    status = loadedIsEnabled ? .stopped : .disabled
    appendLog("Local AI settings loaded.")
  }

  var isServerRunning: Bool {
    server?.isRunning == true
  }

  var baseURL: String {
    settings.baseURL
  }

  var canStart: Bool {
    !isBusy && settings.port > 0 && settings.port <= 65_535 && !settings.trimmedHost.isEmpty
  }

  func startIfEnabled() {
    guard isEnabled else {
      status = .disabled
      return
    }
    startServer()
  }

  func updateSettings(_ newSettings: LocalAISettings) {
    settings = normalizedSettings(newSettings)
    persistSettings()
  }

  func setEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: Self.enabledKey)
    isEnabled = enabled

    if enabled {
      startServer()
    } else {
      stopServer()
      status = .disabled
    }
  }

  func startServer() {
    guard !isBusy else { return }
    guard !isServerRunning else {
      status = .running
      return
    }
    guard settings.port > 0 && settings.port <= 65_535 else {
      status = .failed("Port must be between 1 and 65535.")
      return
    }
    if settings.requiresAPIKey && settings.trimmedAPIKey.isEmpty {
      status = .failed("Set an API key before starting with authentication required or non-loopback host.")
      return
    }

    status = .starting
    appendLog("Starting Local OpenAI API on \(settings.baseURL)...")

    do {
      let runtime = LocalAIRuntimeFactory.make(kind: settings.runtimeKind)
      let newServer = LocalOpenAIServer(settings: settings, runtime: runtime) { [weak self] line in
        Task { @MainActor in
          self?.appendLog(line)
        }
      }
      try newServer.start()
      server = newServer
      status = .running
      appendLog("Server running at \(settings.baseURL)")
    } catch {
      status = .failed(error.localizedDescription)
      appendLog("Start failed: \(error.localizedDescription)")
    }
  }

  func stopServer() {
    guard !isBusy else { return }
    guard let server else {
      status = isEnabled ? .stopped : .disabled
      return
    }

    status = .stopping
    appendLog("Stopping Local OpenAI API...")
    server.stop()
    self.server = nil
    status = isEnabled ? .stopped : .disabled
    appendLog("Server stopped.")
  }

  func restartServer() {
    stopServer()
    startServer()
  }

  func stopForAppTermination() {
    server?.stop()
    server = nil
  }

  func validateChatModel() {
    runValidation(spec: settings.chatSpec)
  }

  func validateEmbeddingModel() {
    runValidation(spec: settings.embeddingSpec)
  }

  func validateModel(alias: String, role: LocalAIModelRole) {
    guard let spec = settings.modelSpec(alias: alias, role: role) else {
      lastOperationOutput = "Validation failed: model '\(alias)' is not configured.\n"
      appendLog("Validation failed for missing model: \(alias)")
      return
    }
    runValidation(spec: spec)
  }

  func unloadAll() {
    isBusy = true
    status = .busy("Unloading")
    lastOperationOutput = "Unloading Local AI runtime...\n"
    let runtime = LocalAIRuntimeFactory.make(kind: settings.runtimeKind)
    Task { @MainActor in
      await runtime.unloadAll()
      isBusy = false
      restoreIdleStatus()
      appendOperationOutput("Unload requested.\n")
      appendLog("Unload requested.")
    }
  }

  func testChat() {
    guard !isBusy else { return }
    isBusy = true
    status = .busy("Testing Chat")
    lastOperationOutput = "Testing chat model '\(settings.trimmedChatAlias)'...\n"
    let currentSettings = settings
    let runtime = LocalAIRuntimeFactory.make(kind: currentSettings.runtimeKind)
    let request = LocalAIChatRequest(
      model: currentSettings.trimmedChatAlias,
      messages: [LocalAIChatMessage(role: "user", content: "Reply with one short sentence.")],
      stream: false,
      temperature: 0.2,
      topP: nil,
      maxTokens: 32,
      stop: nil
    )

    Task { @MainActor in
      do {
        let result = try await runtime.completeChat(request, settings: currentSettings)
        appendOperationOutput("Chat OK: \(result.content)\n")
        appendLog("Chat test completed for \(request.model).")
      } catch {
        appendOperationOutput("Chat failed: \(error.localizedDescription)\n")
        appendLog("Chat test failed: \(error.localizedDescription)")
      }
      isBusy = false
      restoreIdleStatus()
    }
  }

  func sendChat(modelAlias: String, prompt: String) {
    guard !isBusy else { return }
    let model = modelAlias.trimmingCharacters(in: .whitespacesAndNewlines)
    let content = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty, !content.isEmpty else { return }

    let currentSettings = settings
    let history = chatMessages
      .suffix(12)
      .filter { $0.role == "user" || $0.role == "assistant" }
      .map { LocalAIChatMessage(role: $0.role, content: $0.content) }
    let messages = history + [LocalAIChatMessage(role: "user", content: content)]
    let userTurn = LocalAIChatTurn(role: "user", content: content, model: model)

    chatMessages.append(userTurn)
    isBusy = true
    status = .busy("Chatting")
    appendLog("Chat request started for \(model).")

    let runtime = LocalAIRuntimeFactory.make(kind: currentSettings.runtimeKind)
    let request = LocalAIChatRequest(
      model: model,
      messages: messages,
      stream: false,
      temperature: 0.3,
      topP: nil,
      maxTokens: 256,
      stop: nil
    )

    Task { @MainActor in
      do {
        let result = try await runtime.completeChat(request, settings: currentSettings)
        chatMessages.append(LocalAIChatTurn(role: "assistant", content: result.content, model: model))
        appendLog("Chat response completed for \(model).")
      } catch {
        chatMessages.append(LocalAIChatTurn(role: "error", content: error.localizedDescription, model: model))
        appendLog("Chat failed for \(model): \(error.localizedDescription)")
      }
      isBusy = false
      restoreIdleStatus()
    }
  }

  func clearChat() {
    chatMessages.removeAll()
    appendLog("Cleared Local AI chat transcript.")
  }

  func addModel(_ model: LocalAIModelConfiguration) {
    var next = settings
    let normalizedModel = LocalAIModelConfiguration(
      id: model.id,
      alias: model.trimmedAlias,
      role: model.role,
      sourceKind: model.sourceKind,
      path: model.trimmedPath,
      sourceURL: model.trimmedSourceURL,
      notes: model.notes
    )

    next.modelCatalog.removeAll { $0.id == normalizedModel.id || ($0.role == normalizedModel.role && $0.trimmedAlias == normalizedModel.trimmedAlias) }
    next.modelCatalog.append(normalizedModel)

    switch normalizedModel.role {
    case .chat:
      next.chatAlias = normalizedModel.trimmedAlias
      next.chatModelPath = normalizedModel.trimmedPath
    case .embedding:
      next.embeddingAlias = normalizedModel.trimmedAlias
      next.embeddingModelPath = normalizedModel.trimmedPath
    }

    settings = normalizedSettings(next)
    persistSettings()
    appendLog("Added \(normalizedModel.role.title.lowercased()) model '\(normalizedModel.trimmedAlias)'.")
  }

  func clearModelDownloadProgress() {
    guard !modelDownloadProgress.isActive else { return }
    modelDownloadProgress = .idle
  }

  func downloadAndAddModel(alias: String, role: LocalAIModelRole, source: String, localDir: String) {
    guard !isBusy else { return }

    let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    let repo = Self.repoName(from: source)
    let destination = NSString(string: localDir.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
    guard !trimmedAlias.isEmpty else {
      modelDownloadProgress = LocalAIModelDownloadProgress(isActive: false, title: "Download failed", detail: "Name is required.", output: "", completedPath: nil, errorMessage: "Name is required.")
      return
    }
    guard !repo.isEmpty else {
      modelDownloadProgress = LocalAIModelDownloadProgress(isActive: false, title: "Download failed", detail: "Enter a Hugging Face URL or repo like mlx-community/Qwen3-0.6B-4bit.", output: "", completedPath: nil, errorMessage: "Invalid Hugging Face URL/repo.")
      return
    }
    guard !destination.isEmpty else {
      modelDownloadProgress = LocalAIModelDownloadProgress(isActive: false, title: "Download failed", detail: "Download folder is required.", output: "", completedPath: nil, errorMessage: "Download folder is required.")
      return
    }

    let configuredPython = settings.trimmedPythonExecutable
    let managedVenv = Self.managedPythonVenvPath
    let managedPython = "\(managedVenv)/bin/python"
    let shouldUseManagedPython = configuredPython.isEmpty
      || configuredPython == LocalAISettings.defaults.pythonExecutable
      || !FileManager.default.isExecutableFile(atPath: NSString(string: configuredPython).expandingTildeInPath)
    let python = shouldUseManagedPython ? managedPython : NSString(string: configuredPython).expandingTildeInPath
    let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "OkBrainCC"
    let sourceURL = Self.sourceURL(from: source, repo: repo)
    let arguments = [
      "local-ai",
      "download-tiny-model",
      "--python", python,
      "--repo", repo,
      "--local-dir", destination,
    ]

    isBusy = true
    status = .busy("Downloading Model")
    lastOperationOutput = "Downloading \(repo) to \(destination)...\n"
    modelDownloadProgress = LocalAIModelDownloadProgress(
      isActive: true,
      title: "Downloading \(repo)",
      detail: "Starting download...",
      output: "",
      completedPath: nil,
      errorMessage: nil
    )
    appendLog("Downloading model \(repo) to \(destination).")

    Task { @MainActor in
      do {
        let hasMLXDependencies = await Self.pythonHasMLXDependencies(python)
        if shouldUseManagedPython || !hasMLXDependencies {
          var installProgress = modelDownloadProgress
          installProgress.title = "Installing Local AI dependencies"
          installProgress.detail = "Creating/updating Python venv at \(managedVenv)..."
          modelDownloadProgress = installProgress
          appendLog("Installing Local AI Python dependencies into \(managedVenv).")

          let installResult = try await Self.runStreamingProcess(executable, arguments: ["local-ai", "install-python-mlx", "--venv", managedVenv]) { [weak self] line in
            Task { @MainActor in
              self?.appendDownloadOutput(line)
            }
          }

          guard installResult.exitCode == 0 else {
            throw LocalAIError.runtimeFailed(installResult.stderr.isEmpty ? installResult.stdout : installResult.stderr)
          }

          var nextSettings = settings
          nextSettings.pythonExecutable = managedPython
          settings = normalizedSettings(nextSettings)
          persistSettings()
          appendLog("Local AI Python dependencies installed.")
        }

        var downloadProgress = modelDownloadProgress
        downloadProgress.title = "Downloading \(repo)"
        downloadProgress.detail = "Starting model download..."
        modelDownloadProgress = downloadProgress

        let result = try await Self.runStreamingProcess(executable, arguments: arguments) { [weak self] line in
          Task { @MainActor in
            self?.appendDownloadOutput(line)
          }
        }

        guard result.exitCode == 0 else {
          throw LocalAIError.runtimeFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        let downloadedPath = Self.downloadedPath(from: result.stdout) ?? destination
        addModel(LocalAIModelConfiguration(
          alias: trimmedAlias,
          role: role,
          sourceKind: .huggingFace,
          path: downloadedPath,
          sourceURL: sourceURL,
          notes: "Downloaded from \(repo)."
        ))

        modelDownloadProgress = LocalAIModelDownloadProgress(
          isActive: false,
          title: "Download complete",
          detail: "Added '\(trimmedAlias)' from \(repo).",
          output: modelDownloadProgress.output,
          completedPath: downloadedPath,
          errorMessage: nil
        )
        appendOperationOutput("Download complete: \(downloadedPath)\n")
        appendLog("Download complete for \(trimmedAlias).")
      } catch {
        let message = error.localizedDescription
        modelDownloadProgress = LocalAIModelDownloadProgress(
          isActive: false,
          title: "Download failed",
          detail: message,
          output: modelDownloadProgress.output,
          completedPath: nil,
          errorMessage: message
        )
        appendOperationOutput("Download failed: \(message)\n")
        appendLog("Download failed: \(message)")
      }

      isBusy = false
      restoreIdleStatus()
    }
  }

  func testEmbedding() {
    guard !isBusy else { return }
    isBusy = true
    status = .busy("Testing Embedding")
    lastOperationOutput = "Testing embedding model '\(settings.trimmedEmbeddingAlias)'...\n"
    let currentSettings = settings
    let runtime = LocalAIRuntimeFactory.make(kind: currentSettings.runtimeKind)
    let request = LocalAIEmbeddingRequest(model: currentSettings.trimmedEmbeddingAlias, input: ["hello local ai"])

    Task { @MainActor in
      do {
        let result = try await runtime.embed(request, settings: currentSettings)
        let dimensions = result.embeddings.first?.count ?? 0
        appendOperationOutput("Embedding OK: \(dimensions) dimensions.\n")
        appendLog("Embedding test completed with \(dimensions) dimensions.")
      } catch {
        appendOperationOutput("Embedding failed: \(error.localizedDescription)\n")
        appendLog("Embedding test failed: \(error.localizedDescription)")
      }
      isBusy = false
      restoreIdleStatus()
    }
  }

  func copyBaseURL() {
    copyToPasteboard(settings.baseURL)
    appendLog("Copied base URL.")
  }

  func copySampleConfig() {
    let keyLine = settings.requiresAPIKey ? "api_key = \"\(settings.trimmedAPIKey)\"" : "api_key = \"okbraincc-local\""
    let sample = """
    base_url = "\(settings.baseURL)"
    \(keyLine)
    model = "\(settings.trimmedChatAlias)"
    """
    copyToPasteboard(sample)
    appendLog("Copied sample client config.")
  }

  func copyText(_ text: String, logMessage: String) {
    copyToPasteboard(text)
    appendLog(logMessage)
  }

  func openURL(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
    appendLog("Opened \(urlString).")
  }

  func openModelsDirectory() {
    let url = URL(fileURLWithPath: settings.expandedModelDownloadDirectory, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
    appendLog("Opened model download directory.")
  }

  func openModelFolder(_ role: LocalAIModelRole) {
    let spec = role == .chat ? settings.chatSpec : settings.embeddingSpec
    openModelFolder(path: spec.path)
  }

  func openModelFolder(path: String) {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath))
    appendLog("Opened model folder.")
  }

  private func runValidation(spec: LocalAIModelSpec) {
    guard !isBusy else { return }
    isBusy = true
    status = .busy("Validating")
    lastOperationOutput = "Validating \(spec.role.rawValue) model '\(spec.alias)'...\n"
    let currentSettings = settings
    let runtime = LocalAIRuntimeFactory.make(kind: currentSettings.runtimeKind)

    Task { @MainActor in
      let result = await runtime.validate(spec: spec, settings: currentSettings)
      appendOperationOutput("\(result.isUsable ? "OK" : "Failed"): \(result.message)\n")
      appendLog("Validation for \(result.alias): \(result.message)")
      isBusy = false
      restoreIdleStatus()
    }
  }

  private func normalizedSettings(_ newSettings: LocalAISettings) -> LocalAISettings {
    var normalized = newSettings

    if !normalized.modelCatalog.isEmpty {
      if normalized.trimmedChatAlias.isEmpty, let first = normalized.chatModels.first {
        normalized.chatAlias = first.trimmedAlias
      }
      if normalized.trimmedEmbeddingAlias.isEmpty, let first = normalized.embeddingModels.first {
        normalized.embeddingAlias = first.trimmedAlias
      }
    }

    if let chat = normalized.modelSpec(alias: normalized.trimmedChatAlias, role: .chat) {
      normalized.chatAlias = chat.alias
      normalized.chatModelPath = chat.path
    }

    if let embedding = normalized.modelSpec(alias: normalized.trimmedEmbeddingAlias, role: .embedding) {
      normalized.embeddingAlias = embedding.alias
      normalized.embeddingModelPath = embedding.path
    }

    return normalized
  }

  private func restoreIdleStatus() {
    status = isServerRunning ? .running : (isEnabled ? .stopped : .disabled)
  }

  private func appendDownloadOutput(_ line: String) {
    let cleaned = line
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }

    var progress = modelDownloadProgress
    progress.detail = cleaned
    let allLines = (progress.output + cleaned + "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
    progress.output = allLines.suffix(80).joined(separator: "\n")
    modelDownloadProgress = progress
    appendOperationOutput("\(cleaned)\n")
  }

  nonisolated private static func runStreamingProcess(
    _ executable: String,
    arguments: [String],
    onOutput: @escaping @Sendable (String) -> Void
  ) async throws -> LocalAIProcessResult {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments

      let stdout = Pipe()
      let stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr

      let lock = NSLock()
      var stdoutData = Data()
      var stderrData = Data()

      func capture(_ data: Data, isStdout: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isStdout {
          stdoutData.append(data)
        } else {
          stderrData.append(data)
        }
        lock.unlock()

        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text
          .replacingOccurrences(of: "\r", with: "\n")
          .split(separator: "\n", omittingEmptySubsequences: true)
          .suffix(12)
        for line in lines {
          onOutput(String(line))
        }
      }

      stdout.fileHandleForReading.readabilityHandler = { handle in
        capture(handle.availableData, isStdout: true)
      }
      stderr.fileHandleForReading.readabilityHandler = { handle in
        capture(handle.availableData, isStdout: false)
      }

      process.terminationHandler = { terminatedProcess in
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        capture(stdout.fileHandleForReading.readDataToEndOfFile(), isStdout: true)
        capture(stderr.fileHandleForReading.readDataToEndOfFile(), isStdout: false)

        lock.lock()
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        lock.unlock()

        continuation.resume(returning: LocalAIProcessResult(
          exitCode: terminatedProcess.terminationStatus,
          stdout: stdoutText,
          stderr: stderrText
        ))
      }

      do {
        try process.run()
      } catch {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }

  nonisolated private static func downloadedPath(from stdout: String) -> String? {
    stdout
      .split(separator: "\n")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .last { !$0.isEmpty }
  }

  nonisolated private static func pythonHasMLXDependencies(_ python: String) async -> Bool {
    guard FileManager.default.isExecutableFile(atPath: python) else { return false }
    let result = try? await runStreamingProcess(
      python,
      arguments: ["-c", "import huggingface_hub, mlx_lm"],
      onOutput: { _ in }
    )
    return result?.exitCode == 0
  }

  nonisolated private static var managedPythonVenvPath: String {
    NSString(string: "~/.okbraincc/local-ai-venv").expandingTildeInPath
  }

  nonisolated private static func repoName(from source: String) -> String {
    var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return "" }

    if value.hasPrefix("https://huggingface.co/") {
      value.removeFirst("https://huggingface.co/".count)
    } else if value.hasPrefix("http://huggingface.co/") {
      value.removeFirst("http://huggingface.co/".count)
    }

    value = value.split(separator: "?").first.map(String.init) ?? value
    let parts = value.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return "" }
    return "\(parts[0])/\(parts[1])"
  }

  nonisolated private static func sourceURL(from source: String, repo: String) -> String {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
      return trimmed
    }
    return repo.isEmpty ? trimmed : "https://huggingface.co/\(repo)"
  }

  private func appendLog(_ line: String) {
    let stamped = "[\(Self.timestampFormatter.string(from: Date()))] \(line)"
    let all = (latestLogLines + stamped + "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
    latestLogLines = all.suffix(120).joined(separator: "\n")
  }

  private func appendOperationOutput(_ text: String) {
    lastOperationOutput += text
  }

  private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func persistSettings() {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: Self.settingsKey)
  }

  private static func loadSettings(defaults: UserDefaults) -> LocalAISettings {
    guard let data = defaults.data(forKey: settingsKey),
          let settings = try? JSONDecoder().decode(LocalAISettings.self, from: data) else {
      return .defaults
    }
    return settings
  }

  private static let settingsKey = "LocalAI.settings"
  private static let enabledKey = "LocalAI.enabled"

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()
}

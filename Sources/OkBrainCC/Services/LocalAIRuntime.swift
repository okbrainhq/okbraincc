import Foundation

protocol LocalAIRuntime: Sendable {
  func validate(spec: LocalAIModelSpec, settings: LocalAISettings) async -> LocalAIValidationResult
  func completeChat(_ request: LocalAIChatRequest, settings: LocalAISettings) async throws -> LocalAIChatResult
  func streamChat(_ request: LocalAIChatRequest, settings: LocalAISettings) async throws -> AsyncThrowingStream<String, Error>
  func embed(_ request: LocalAIEmbeddingRequest, settings: LocalAISettings) async throws -> LocalAIEmbeddingResult
  func unloadAll() async
}

enum LocalAIRuntimeFactory {
  static func make(kind: LocalAIRuntimeKind) -> any LocalAIRuntime {
    switch kind {
    case .mock:
      MockLocalAIRuntime()
    case .mlxPython:
      MLXPythonLocalAIRuntime()
    }
  }
}

actor MockLocalAIRuntime: LocalAIRuntime {
  private var lastUsedAt = Date()

  func validate(spec: LocalAIModelSpec, settings: LocalAISettings) async -> LocalAIValidationResult {
    LocalAIValidationResult(
      role: spec.role,
      alias: spec.alias,
      path: spec.path,
      isUsable: !spec.alias.isEmpty,
      message: spec.alias.isEmpty ? "Alias is empty." : "Mock runtime is ready for \(spec.alias)."
    )
  }

  func completeChat(_ request: LocalAIChatRequest, settings: LocalAISettings) async throws -> LocalAIChatResult {
    lastUsedAt = Date()
    let lastUser = request.messages.last(where: { $0.role == "user" })?.content ?? ""
    let content = "OKBrainCC mock response for \(request.model): \(lastUser.isEmpty ? "hello" : lastUser)"
    return LocalAIChatResult(
      content: content,
      promptTokens: estimateTokens(request.messages.map(\.content).joined(separator: " ")),
      completionTokens: estimateTokens(content),
      finishReason: "stop"
    )
  }

  func streamChat(_ request: LocalAIChatRequest, settings: LocalAISettings) async throws -> AsyncThrowingStream<String, Error> {
    let result = try await completeChat(request, settings: settings)
    let chunks = splitForStreaming(result.content)
    return AsyncThrowingStream { continuation in
      Task {
        for chunk in chunks {
          try? await Task.sleep(for: .milliseconds(20))
          continuation.yield(chunk)
        }
        continuation.finish()
      }
    }
  }

  func embed(_ request: LocalAIEmbeddingRequest, settings: LocalAISettings) async throws -> LocalAIEmbeddingResult {
    lastUsedAt = Date()
    let vectors = request.input.map { deterministicEmbedding(for: $0, dimensions: 1024) }
    return LocalAIEmbeddingResult(
      embeddings: vectors,
      promptTokens: estimateTokens(request.input.joined(separator: " "))
    )
  }

  func unloadAll() async {
    lastUsedAt = Date()
  }

  private func estimateTokens(_ text: String) -> Int {
    max(1, text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count)
  }

  private func splitForStreaming(_ text: String) -> [String] {
    var chunks: [String] = []
    var current = ""
    for character in text {
      current.append(character)
      if current.count >= 8 || character == " " {
        chunks.append(current)
        current = ""
      }
    }
    if !current.isEmpty {
      chunks.append(current)
    }
    return chunks
  }

  private func deterministicEmbedding(for text: String, dimensions: Int) -> [Float] {
    let bytes: [UInt8] = text.utf8.isEmpty ? [0] : Array(text.utf8)
    var values: [Float] = []
    values.reserveCapacity(dimensions)

    for index in 0..<dimensions {
      let byte = bytes[index % bytes.count]
      let mixed = UInt32(byte) &+ UInt32(index &* 31) &+ UInt32((index >> 1) &* 17)
      let normalized = (Float(mixed % 2000) / 1000.0) - 1.0
      values.append(normalized)
    }

    let norm = sqrt(values.reduce(Float(0)) { $0 + ($1 * $1) })
    guard norm > 0 else { return values }
    return values.map { $0 / norm }
  }
}

actor MLXPythonLocalAIRuntime: LocalAIRuntime {
  private var isChatBusy = false
  private var isEmbeddingBusy = false

  func validate(spec: LocalAIModelSpec, settings: LocalAISettings) async -> LocalAIValidationResult {
    guard !spec.alias.isEmpty else {
      return LocalAIValidationResult(role: spec.role, alias: spec.alias, path: spec.path, isUsable: false, message: "Alias is empty.")
    }

    guard !spec.path.isEmpty else {
      return LocalAIValidationResult(role: spec.role, alias: spec.alias, path: spec.path, isUsable: false, message: "No local model folder configured.")
    }

    guard spec.existsOnDisk else {
      return LocalAIValidationResult(role: spec.role, alias: spec.alias, path: spec.path, isUsable: false, message: "Model folder was not found: \(spec.expandedPath)")
    }

    if spec.role == .chat {
      do {
        let request = LocalAIChatRequest(
          model: spec.alias,
          messages: [LocalAIChatMessage(role: "user", content: "Say OK.")],
          stream: false,
          temperature: 0,
          topP: nil,
          maxTokens: 4,
          stop: nil
        )
        _ = try await completeChat(request, settings: settings)
        return LocalAIValidationResult(role: spec.role, alias: spec.alias, path: spec.path, isUsable: true, message: "Chat model loaded and generated a test response.")
      } catch {
        return LocalAIValidationResult(role: spec.role, alias: spec.alias, path: spec.path, isUsable: false, message: error.localizedDescription)
      }
    }

    return LocalAIValidationResult(role: spec.role, alias: spec.alias, path: spec.path, isUsable: true, message: "Embedding folder exists. Runtime validation will occur on first embedding request.")
  }

  func completeChat(_ request: LocalAIChatRequest, settings: LocalAISettings) async throws -> LocalAIChatResult {
    guard !isChatBusy else { throw LocalAIError.runtimeBusy }
    isChatBusy = true
    defer { isChatBusy = false }

    guard let spec = settings.modelSpec(alias: request.model, role: .chat) else {
      throw LocalAIError.modelNotConfigured(request.model)
    }
    try ensureUsable(spec: spec, requestedModel: request.model)

    let payload: [String: Any] = [
      "model_path": spec.expandedPath,
      "messages": request.messages.map { ["role": $0.role, "content": $0.content] },
      "max_tokens": request.maxTokens ?? 128,
      "temperature": request.temperature ?? 0.7,
      "top_p": request.topP ?? 0.95,
    ]

    let result = try await LocalAIPythonBridge.run(
      command: "chat",
      payload: payload,
      pythonExecutable: settings.trimmedPythonExecutable
    )

    guard result.exitCode == 0 else {
      throw LocalAIError.modelLoadFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    guard let data = result.stdout.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LocalAIError.runtimeFailed("MLX bridge returned invalid JSON: \(result.stdout.prefix(300))")
    }

    let content = json["content"] as? String ?? ""
    let promptTokens = json["prompt_tokens"] as? Int ?? estimateTokens(request.messages.map(\.content).joined(separator: " "))
    let completionTokens = json["completion_tokens"] as? Int ?? estimateTokens(content)

    return LocalAIChatResult(content: content, promptTokens: promptTokens, completionTokens: completionTokens, finishReason: "stop")
  }

  func streamChat(_ request: LocalAIChatRequest, settings: LocalAISettings) async throws -> AsyncThrowingStream<String, Error> {
    let result = try await completeChat(request, settings: settings)
    let chunks = splitForStreaming(result.content)
    return AsyncThrowingStream { continuation in
      Task {
        for chunk in chunks {
          continuation.yield(chunk)
          try? await Task.sleep(for: .milliseconds(15))
        }
        continuation.finish()
      }
    }
  }

  func embed(_ request: LocalAIEmbeddingRequest, settings: LocalAISettings) async throws -> LocalAIEmbeddingResult {
    guard !isEmbeddingBusy else { throw LocalAIError.runtimeBusy }
    isEmbeddingBusy = true
    defer { isEmbeddingBusy = false }

    guard let spec = settings.modelSpec(alias: request.model, role: .embedding) else {
      throw LocalAIError.modelNotConfigured(request.model)
    }
    try ensureUsable(spec: spec, requestedModel: request.model)

    let payload: [String: Any] = [
      "model_path": spec.expandedPath,
      "input": request.input,
      "dimensions": 1024,
    ]

    let result = try await LocalAIPythonBridge.run(
      command: "embed",
      payload: payload,
      pythonExecutable: settings.trimmedPythonExecutable
    )

    guard result.exitCode == 0 else {
      throw LocalAIError.modelLoadFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    guard let data = result.stdout.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let embeddings = json["embeddings"] as? [[Double]] else {
      throw LocalAIError.runtimeFailed("MLX bridge returned invalid embedding JSON: \(result.stdout.prefix(300))")
    }

    let vectors = embeddings.map { $0.map(Float.init) }
    let promptTokens = json["prompt_tokens"] as? Int ?? estimateTokens(request.input.joined(separator: " "))
    return LocalAIEmbeddingResult(embeddings: vectors, promptTokens: promptTokens)
  }

  func unloadAll() async {}

  private func ensureUsable(spec: LocalAIModelSpec, requestedModel: String) throws {
    guard requestedModel == spec.alias else {
      throw LocalAIError.modelNotConfigured(requestedModel)
    }
    guard spec.isConfigured else {
      throw LocalAIError.modelNotConfigured(requestedModel)
    }
    guard spec.existsOnDisk else {
      throw LocalAIError.modelNotFound(requestedModel)
    }
  }

  private func estimateTokens(_ text: String) -> Int {
    max(1, text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count)
  }

  private func splitForStreaming(_ text: String) -> [String] {
    var chunks: [String] = []
    var current = ""
    for character in text {
      current.append(character)
      if current.count >= 8 || character == " " {
        chunks.append(current)
        current = ""
      }
    }
    if !current.isEmpty {
      chunks.append(current)
    }
    return chunks
  }
}

enum LocalAIPythonBridge {
  static func run(command: String, payload: [String: Any], pythonExecutable: String) async throws -> LocalAIProcessResult {
    let executable = pythonExecutable.isEmpty ? "/usr/bin/python3" : pythonExecutable
    guard let bridgeURL = Bundle.module.url(forResource: "local_ai_mlx_bridge", withExtension: "py") else {
      throw LocalAIError.runtimeFailed("Bundled MLX bridge script was not found.")
    }

    let inputData = LocalAIJSON.data(payload)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = [bridgeURL.path, command]

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    stdin.fileHandleForWriting.write(inputData)
    try? stdin.fileHandleForWriting.close()

    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        process.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        continuation.resume(returning: LocalAIProcessResult(
          exitCode: process.terminationStatus,
          stdout: String(data: outData, encoding: .utf8) ?? "",
          stderr: String(data: errData, encoding: .utf8) ?? ""
        ))
      }
    }
  }
}

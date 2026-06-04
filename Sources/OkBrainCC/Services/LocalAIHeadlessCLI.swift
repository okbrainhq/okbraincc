import Foundation

enum LocalAIHeadlessCLI {
  static func runAndExitIfRequested() {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.first == "local-ai" else { return }

    let semaphore = DispatchSemaphore(value: 0)
    var exitCode = 0

    signal(SIGINT) { _ in
      Foundation.exit(0)
    }
    signal(SIGTERM) { _ in
      Foundation.exit(0)
    }

    Task.detached {
      exitCode = await run(Array(args.dropFirst()))
      semaphore.signal()
    }

    semaphore.wait()
    Foundation.exit(Int32(exitCode))
  }

  private static func run(_ args: [String]) async -> Int {
    guard let command = args.first else {
      printUsage()
      return 2
    }

    let options = CLIOptions(Array(args.dropFirst()))

    do {
      switch command {
      case "serve":
        try await serve(options)
        return 0
      case "validate":
        try await validate(options)
        return 0
      case "e2e":
        try await e2e(options)
        return 0
      case "download-tiny-model":
        try await downloadTinyModel(options)
        return 0
      case "install-python-mlx":
        try await installPythonMLX(options)
        return 0
      case "help", "--help", "-h":
        printUsage()
        return 0
      default:
        fputs("Unknown local-ai command: \(command)\n\n", stderr)
        printUsage()
        return 2
      }
    } catch {
      fputs("local-ai \(command) failed: \(error.localizedDescription)\n", stderr)
      return 1
    }
  }

  private static func serve(_ options: CLIOptions) async throws {
    let settings = settings(from: options)
    let runtime = LocalAIRuntimeFactory.make(kind: settings.runtimeKind)
    let server = LocalOpenAIServer(settings: settings, runtime: runtime) { line in
      print(line)
      fflush(stdout)
    }

    try server.start()
    print("OKBrainCC Local OpenAI API running")
    print("Base URL: \(settings.baseURL)")
    print("Health: \(settings.healthURL)")
    print("Runtime: \(settings.runtimeKind.rawValue)")
    fflush(stdout)

    while true {
      try await Task.sleep(for: .seconds(3600))
    }
  }

  private static func validate(_ options: CLIOptions) async throws {
    let settings = settings(from: options)
    let runtime = LocalAIRuntimeFactory.make(kind: settings.runtimeKind)
    let chat = await runtime.validate(spec: settings.chatSpec, settings: settings)
    let embedding = await runtime.validate(spec: settings.embeddingSpec, settings: settings)
    let object: [String: Any] = [
      "runtime": settings.runtimeKind.rawValue,
      "chat": validationJSON(chat),
      "embedding": validationJSON(embedding),
    ]
    print(LocalAIJSON.string(object, pretty: true))
  }

  private static func e2e(_ options: CLIOptions) async throws {
    var settings = settings(from: options)
    if options.has("download-tiny-model") {
      let path = try await downloadedTinyModelPath(options)
      settings.chatModelPath = path
      if settings.trimmedEmbeddingModelPath.isEmpty {
        settings.embeddingModelPath = path
      }
      if settings.runtimeKind == .mock {
        settings.runtimeKind = .mlxPython
      }
      print("Using downloaded chat model: \(path)")
    }

    let runtime = LocalAIRuntimeFactory.make(kind: settings.runtimeKind)
    let server = LocalOpenAIServer(settings: settings, runtime: runtime) { line in
      print(line)
      fflush(stdout)
    }
    try server.start()
    defer { server.stop() }

    try await waitForHealth(settings: settings)
    try await assertModels(settings: settings)
    try await assertChat(settings: settings)
    try await assertStreamingChat(settings: settings)
    try await assertEmbeddings(settings: settings)

    print("✅ local-ai E2E passed for \(settings.runtimeKind.rawValue) at \(settings.baseURL)")
  }

  private static func downloadTinyModel(_ options: CLIOptions) async throws {
    let path = try await downloadedTinyModelPath(options)
    print(path)
  }

  private static func downloadedTinyModelPath(_ options: CLIOptions) async throws -> String {
    let settings = settings(from: options)
    let repo = options.value("repo") ?? "mlx-community/Qwen3-0.6B-4bit"
    let localDir = options.value("local-dir") ?? ".build/local-ai-models/\(repo.replacingOccurrences(of: "/", with: "__"))"
    let payload: [String: Any] = [
      "repo": repo,
      "local_dir": localDir,
    ]
    let result = try await LocalAIPythonBridge.run(command: "download", payload: payload, pythonExecutable: settings.trimmedPythonExecutable)
    guard result.exitCode == 0 else {
      throw LocalAIError.runtimeFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
    }
    guard let data = result.stdout.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let path = json["path"] as? String else {
      throw LocalAIError.runtimeFailed("Download bridge returned invalid JSON: \(result.stdout)")
    }
    return path
  }

  private static func installPythonMLX(_ options: CLIOptions) async throws {
    let venv = options.value("venv") ?? ".build/local-ai-venv"
    let systemPython = options.value("python") ?? "/usr/bin/python3"
    try await runProcess(systemPython, ["-m", "venv", venv])

    let python = "\(venv)/bin/python"
    try await runProcess(python, ["-m", "pip", "install", "--upgrade", "pip"])
    try await runProcess(python, ["-m", "pip", "install", "mlx-lm", "huggingface_hub"])

    print("✅ Installed MLX Python bridge dependencies")
    print("Python: \(python)")
  }

  private static func settings(from options: CLIOptions) -> LocalAISettings {
    var settings = LocalAISettings.defaults
    settings.host = options.value("host") ?? settings.host
    settings.port = Int(options.value("port") ?? "") ?? settings.port
    if let runtimeValue = options.value("runtime") {
      settings.runtimeKind = LocalAIRuntimeKind(rawValue: runtimeValue) ?? (runtimeValue == "mlx-python" ? .mlxPython : settings.runtimeKind)
    }
    settings.pythonExecutable = options.value("python") ?? options.value("python-executable") ?? settings.pythonExecutable
    settings.chatAlias = options.value("chat-alias") ?? settings.chatAlias
    settings.chatModelPath = options.value("chat-path") ?? options.value("chat-model-path") ?? settings.chatModelPath
    settings.embeddingAlias = options.value("embedding-alias") ?? settings.embeddingAlias
    settings.embeddingModelPath = options.value("embedding-path") ?? options.value("embedding-model-path") ?? settings.embeddingModelPath
    settings.idleUnloadSeconds = Int(options.value("idle-unload-seconds") ?? "") ?? settings.idleUnloadSeconds
    settings.allowNoAuthOnLoopback = !options.has("require-api-key")
    settings.apiKey = options.value("api-key") ?? settings.apiKey
    return settings
  }

  private static func validationJSON(_ result: LocalAIValidationResult) -> [String: Any] {
    [
      "role": result.role.rawValue,
      "alias": result.alias,
      "path": result.path,
      "usable": result.isUsable,
      "message": result.message,
    ]
  }

  private static func waitForHealth(settings: LocalAISettings) async throws {
    for _ in 0..<50 {
      do {
        let (data, response) = try await URLSession.shared.data(from: URL(string: settings.healthURL)!)
        if (response as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["status"] as? String == "ok" {
          return
        }
      } catch {
        try await Task.sleep(for: .milliseconds(100))
      }
    }
    throw LocalAIError.runtimeFailed("Server did not become healthy at \(settings.healthURL)")
  }

  private static func assertModels(settings: LocalAISettings) async throws {
    let (data, response) = try await URLSession.shared.data(from: URL(string: "\(settings.baseURL)/models")!)
    try assertStatus(response, expected: 200, data: data)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["object"] as? String == "list",
          let models = json["data"] as? [[String: Any]],
          models.contains(where: { $0["id"] as? String == settings.trimmedChatAlias }) else {
      throw LocalAIError.runtimeFailed("/v1/models did not include chat alias. Response: \(String(data: data, encoding: .utf8) ?? "")")
    }
    print("✅ /v1/models")
  }

  private static func assertChat(settings: LocalAISettings) async throws {
    let body: [String: Any] = [
      "model": settings.trimmedChatAlias,
      "messages": [["role": "user", "content": "Say hello in five words or less."]],
      "max_tokens": 24,
    ]
    let (data, response) = try await postJSON(url: "\(settings.baseURL)/chat/completions", body: body)
    try assertStatus(response, expected: 200, data: data)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["object"] as? String == "chat.completion",
          let choices = json["choices"] as? [[String: Any]],
          let message = choices.first?["message"] as? [String: Any],
          let content = message["content"] as? String,
          !content.isEmpty else {
      throw LocalAIError.runtimeFailed("Chat completion response shape was invalid: \(String(data: data, encoding: .utf8) ?? "")")
    }
    print("✅ /v1/chat/completions")
  }

  private static func assertStreamingChat(settings: LocalAISettings) async throws {
    let body: [String: Any] = [
      "model": settings.trimmedChatAlias,
      "messages": [["role": "user", "content": "Stream a tiny response."]],
      "max_tokens": 24,
      "stream": true,
    ]
    let (data, response) = try await postJSON(url: "\(settings.baseURL)/chat/completions", body: body)
    try assertStatus(response, expected: 200, data: data)
    let text = String(data: data, encoding: .utf8) ?? ""
    guard text.contains("data:"), text.contains("[DONE]") else {
      throw LocalAIError.runtimeFailed("Streaming response did not contain SSE data and [DONE]: \(text)")
    }
    print("✅ streaming /v1/chat/completions")
  }

  private static func assertEmbeddings(settings: LocalAISettings) async throws {
    let body: [String: Any] = [
      "model": settings.trimmedEmbeddingAlias,
      "input": ["hello", "world"],
    ]
    let (data, response) = try await postJSON(url: "\(settings.baseURL)/embeddings", body: body)
    try assertStatus(response, expected: 200, data: data)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["object"] as? String == "list",
          let rows = json["data"] as? [[String: Any]],
          rows.count == 2,
          let first = rows.first?["embedding"] as? [Double],
          first.count == 1024 else {
      throw LocalAIError.runtimeFailed("Embedding response shape was invalid: \(String(data: data, encoding: .utf8) ?? "")")
    }
    print("✅ /v1/embeddings")
  }

  private static func postJSON(url: String, body: [String: Any]) async throws -> (Data, URLResponse) {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = LocalAIJSON.data(body)
    return try await URLSession.shared.data(for: request)
  }

  private static func assertStatus(_ response: URLResponse, expected: Int, data: Data) throws {
    let actual = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard actual == expected else {
      throw LocalAIError.runtimeFailed("Expected HTTP \(expected), got \(actual): \(String(data: data, encoding: .utf8) ?? "")")
    }
  }

  private static func runProcess(_ executable: String, _ arguments: [String]) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw LocalAIError.runtimeFailed("\(executable) \(arguments.joined(separator: " ")) exited with code \(process.terminationStatus)")
    }
  }

  private static func printUsage() {
    print("""
    Usage:
      OkBrainCC local-ai serve [--runtime mock|mlxPython|mlx-python] [--host 127.0.0.1] [--port 11535]
      OkBrainCC local-ai validate [options]
      OkBrainCC local-ai e2e [--runtime mock|mlxPython|mlx-python] [--port 11536] [--download-tiny-model]
      OkBrainCC local-ai install-python-mlx [--venv .build/local-ai-venv]
      OkBrainCC local-ai download-tiny-model [--python .build/local-ai-venv/bin/python]

    Common options:
      --chat-alias qwen3.5:4b
      --chat-path /path/to/local/mlx/chat/model
      --embedding-alias qwen3-embedding
      --embedding-path /path/to/local/mlx/embedding/model
      --python /path/to/python
      --api-key token --require-api-key
    """)
  }
}

private struct CLIOptions {
  private var values: [String: String] = [:]
  private var flags: Set<String> = []

  init(_ args: [String]) {
    var index = 0
    while index < args.count {
      let arg = args[index]
      guard arg.hasPrefix("--") else {
        index += 1
        continue
      }

      let stripped = String(arg.dropFirst(2))
      if let equalsIndex = stripped.firstIndex(of: "=") {
        let key = String(stripped[..<equalsIndex])
        let value = String(stripped[stripped.index(after: equalsIndex)...])
        values[key] = value
        index += 1
      } else if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
        values[stripped] = args[index + 1]
        index += 2
      } else {
        flags.insert(stripped)
        index += 1
      }
    }
  }

  func value(_ key: String) -> String? {
    values[key]
  }

  func has(_ key: String) -> Bool {
    flags.contains(key) || values[key] == "true"
  }
}

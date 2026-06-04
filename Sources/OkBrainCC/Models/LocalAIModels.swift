import Foundation

struct LocalAISettings: Codable, Hashable, Sendable {
  var host: String
  var port: Int
  var startOnLaunch: Bool
  var runtimeKind: LocalAIRuntimeKind
  var pythonExecutable: String
  var chatAlias: String
  var chatModelPath: String
  var embeddingAlias: String
  var embeddingModelPath: String
  var idleUnloadSeconds: Int
  var allowNoAuthOnLoopback: Bool
  var apiKey: String
  var modelDownloadDirectory: String
  var modelCatalog: [LocalAIModelConfiguration]

  init(
    host: String,
    port: Int,
    startOnLaunch: Bool,
    runtimeKind: LocalAIRuntimeKind,
    pythonExecutable: String,
    chatAlias: String,
    chatModelPath: String,
    embeddingAlias: String,
    embeddingModelPath: String,
    idleUnloadSeconds: Int,
    allowNoAuthOnLoopback: Bool,
    apiKey: String,
    modelDownloadDirectory: String,
    modelCatalog: [LocalAIModelConfiguration]
  ) {
    self.host = host
    self.port = port
    self.startOnLaunch = startOnLaunch
    self.runtimeKind = runtimeKind
    self.pythonExecutable = pythonExecutable
    self.chatAlias = chatAlias
    self.chatModelPath = chatModelPath
    self.embeddingAlias = embeddingAlias
    self.embeddingModelPath = embeddingModelPath
    self.idleUnloadSeconds = idleUnloadSeconds
    self.allowNoAuthOnLoopback = allowNoAuthOnLoopback
    self.apiKey = apiKey
    self.modelDownloadDirectory = modelDownloadDirectory
    self.modelCatalog = modelCatalog
  }

  static let defaults = LocalAISettings(
    host: "127.0.0.1",
    port: 11535,
    startOnLaunch: false,
    runtimeKind: .mock,
    pythonExecutable: "/usr/bin/python3",
    chatAlias: "qwen3:0.6b",
    chatModelPath: "",
    embeddingAlias: "qwen3-embedding",
    embeddingModelPath: "",
    idleUnloadSeconds: 300,
    allowNoAuthOnLoopback: true,
    apiKey: "",
    modelDownloadDirectory: "~/.okbraincc/models",
    modelCatalog: []
  )

  var trimmedHost: String {
    host.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedChatAlias: String {
    chatAlias.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedChatModelPath: String {
    chatModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedEmbeddingAlias: String {
    embeddingAlias.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedEmbeddingModelPath: String {
    embeddingModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedPythonExecutable: String {
    pythonExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedAPIKey: String {
    apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedModelDownloadDirectory: String {
    modelDownloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var expandedModelDownloadDirectory: String {
    NSString(string: trimmedModelDownloadDirectory.isEmpty ? Self.defaults.modelDownloadDirectory : trimmedModelDownloadDirectory).expandingTildeInPath
  }

  var baseURL: String {
    "http://\(trimmedHost.isEmpty ? Self.defaults.host : trimmedHost):\(port)/v1"
  }

  var healthURL: String {
    "http://\(trimmedHost.isEmpty ? Self.defaults.host : trimmedHost):\(port)/health"
  }

  var normalizedIdleUnloadSeconds: Int {
    max(5, idleUnloadSeconds)
  }

  var isLoopbackOnly: Bool {
    let value = trimmedHost
    return value == "127.0.0.1" || value == "localhost" || value == "::1"
  }

  var requiresAPIKey: Bool {
    !isLoopbackOnly || !allowNoAuthOnLoopback
  }

  var effectiveModelCatalog: [LocalAIModelConfiguration] {
    var catalog = modelCatalog

    if catalog.isEmpty {
      if !trimmedChatAlias.isEmpty || !trimmedChatModelPath.isEmpty {
        catalog.append(LocalAIModelConfiguration(
          alias: trimmedChatAlias,
          role: .chat,
          path: trimmedChatModelPath,
          sourceURL: "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit",
          notes: "Starter chat model row. Pick a downloaded MLX model folder."
        ))
      }

      if !trimmedEmbeddingAlias.isEmpty || !trimmedEmbeddingModelPath.isEmpty {
        catalog.append(LocalAIModelConfiguration(
          alias: trimmedEmbeddingAlias,
          role: .embedding,
          path: trimmedEmbeddingModelPath,
          sourceURL: "https://huggingface.co/models?library=mlx&search=embedding",
          notes: "Starter embedding model row. Pick a downloaded MLX embedding model folder."
        ))
      }
    }

    return catalog
  }

  var chatModels: [LocalAIModelConfiguration] {
    effectiveModelCatalog.filter { $0.role == .chat && !$0.trimmedAlias.isEmpty }
  }

  var embeddingModels: [LocalAIModelConfiguration] {
    effectiveModelCatalog.filter { $0.role == .embedding && !$0.trimmedAlias.isEmpty }
  }

  var chatSpec: LocalAIModelSpec {
    modelSpec(alias: trimmedChatAlias, role: .chat) ?? LocalAIModelSpec(alias: trimmedChatAlias, path: trimmedChatModelPath, role: .chat)
  }

  var embeddingSpec: LocalAIModelSpec {
    modelSpec(alias: trimmedEmbeddingAlias, role: .embedding) ?? LocalAIModelSpec(alias: trimmedEmbeddingAlias, path: trimmedEmbeddingModelPath, role: .embedding)
  }

  func modelSpecs(role: LocalAIModelRole) -> [LocalAIModelSpec] {
    var seen = Set<String>()
    return effectiveModelCatalog.compactMap { model in
      guard model.role == role else { return nil }
      let spec = model.spec
      guard !spec.alias.isEmpty else { return nil }
      let key = "\(role.rawValue):\(spec.alias)"
      guard seen.insert(key).inserted else { return nil }
      return spec
    }
  }

  func modelSpec(alias: String, role: LocalAIModelRole) -> LocalAIModelSpec? {
    let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }

    if let model = effectiveModelCatalog.first(where: { $0.role == role && $0.trimmedAlias == normalized }) {
      return model.spec
    }

    if role == .chat, normalized == trimmedChatAlias {
      return LocalAIModelSpec(alias: trimmedChatAlias, path: trimmedChatModelPath, role: .chat)
    }

    if role == .embedding, normalized == trimmedEmbeddingAlias {
      return LocalAIModelSpec(alias: trimmedEmbeddingAlias, path: trimmedEmbeddingModelPath, role: .embedding)
    }

    return nil
  }

  private enum CodingKeys: String, CodingKey {
    case host
    case port
    case startOnLaunch
    case runtimeKind
    case pythonExecutable
    case chatAlias
    case chatModelPath
    case embeddingAlias
    case embeddingModelPath
    case idleUnloadSeconds
    case allowNoAuthOnLoopback
    case apiKey
    case modelDownloadDirectory
    case modelCatalog
  }

  init(from decoder: Decoder) throws {
    let defaults = Self.defaults
    let container = try decoder.container(keyedBy: CodingKeys.self)
    host = try container.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
    port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
    startOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .startOnLaunch) ?? defaults.startOnLaunch
    runtimeKind = try container.decodeIfPresent(LocalAIRuntimeKind.self, forKey: .runtimeKind) ?? defaults.runtimeKind
    pythonExecutable = try container.decodeIfPresent(String.self, forKey: .pythonExecutable) ?? defaults.pythonExecutable
    chatAlias = try container.decodeIfPresent(String.self, forKey: .chatAlias) ?? defaults.chatAlias
    chatModelPath = try container.decodeIfPresent(String.self, forKey: .chatModelPath) ?? defaults.chatModelPath
    embeddingAlias = try container.decodeIfPresent(String.self, forKey: .embeddingAlias) ?? defaults.embeddingAlias
    embeddingModelPath = try container.decodeIfPresent(String.self, forKey: .embeddingModelPath) ?? defaults.embeddingModelPath
    idleUnloadSeconds = try container.decodeIfPresent(Int.self, forKey: .idleUnloadSeconds) ?? defaults.idleUnloadSeconds
    allowNoAuthOnLoopback = try container.decodeIfPresent(Bool.self, forKey: .allowNoAuthOnLoopback) ?? defaults.allowNoAuthOnLoopback
    apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
    modelDownloadDirectory = try container.decodeIfPresent(String.self, forKey: .modelDownloadDirectory) ?? defaults.modelDownloadDirectory
    modelCatalog = try container.decodeIfPresent([LocalAIModelConfiguration].self, forKey: .modelCatalog) ?? defaults.modelCatalog
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(host, forKey: .host)
    try container.encode(port, forKey: .port)
    try container.encode(startOnLaunch, forKey: .startOnLaunch)
    try container.encode(runtimeKind, forKey: .runtimeKind)
    try container.encode(pythonExecutable, forKey: .pythonExecutable)
    try container.encode(chatAlias, forKey: .chatAlias)
    try container.encode(chatModelPath, forKey: .chatModelPath)
    try container.encode(embeddingAlias, forKey: .embeddingAlias)
    try container.encode(embeddingModelPath, forKey: .embeddingModelPath)
    try container.encode(idleUnloadSeconds, forKey: .idleUnloadSeconds)
    try container.encode(allowNoAuthOnLoopback, forKey: .allowNoAuthOnLoopback)
    try container.encode(apiKey, forKey: .apiKey)
    try container.encode(modelDownloadDirectory, forKey: .modelDownloadDirectory)
    try container.encode(modelCatalog, forKey: .modelCatalog)
  }
}

enum LocalAIRuntimeKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case mock
  case mlxPython

  var id: String { rawValue }

  var title: String {
    switch self {
    case .mock:
      "Mock (E2E)"
    case .mlxPython:
      "MLX Python bridge"
    }
  }

  var description: String {
    switch self {
    case .mock:
      "Deterministic runtime for headless and UI E2E tests."
    case .mlxPython:
      "Runs local MLX models through the bundled Python bridge script."
    }
  }
}

enum LocalAIModelRole: String, Codable, CaseIterable, Identifiable, Sendable {
  case chat
  case embedding

  var id: String { rawValue }

  var title: String {
    switch self {
    case .chat:
      "Chat"
    case .embedding:
      "Embedding"
    }
  }

  var shortHint: String {
    switch self {
    case .chat:
      "Use for chat/completions."
    case .embedding:
      "Use only for /v1/embeddings."
    }
  }

  var systemImage: String {
    switch self {
    case .chat:
      "text.bubble"
    case .embedding:
      "point.3.filled.connected.trianglepath.dotted"
    }
  }
}

enum LocalAIModelSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case localFolder
  case huggingFace

  var id: String { rawValue }

  var title: String {
    switch self {
    case .localFolder:
      "Local folder"
    case .huggingFace:
      "Hugging Face / MLX"
    }
  }

  var shortTitle: String {
    switch self {
    case .localFolder:
      "Local"
    case .huggingFace:
      "Hugging Face"
    }
  }
}

struct LocalAIModelDownloadProgress: Equatable, Sendable {
  var isActive: Bool
  var title: String
  var detail: String
  var output: String
  var completedPath: String?
  var errorMessage: String?

  static let idle = LocalAIModelDownloadProgress(
    isActive: false,
    title: "",
    detail: "",
    output: "",
    completedPath: nil,
    errorMessage: nil
  )

  var hasResult: Bool {
    completedPath != nil || errorMessage != nil
  }
}

struct LocalAIModelConfiguration: Codable, Identifiable, Hashable, Sendable {
  var id: UUID
  var alias: String
  var role: LocalAIModelRole
  var sourceKind: LocalAIModelSourceKind
  var path: String
  var sourceURL: String
  var notes: String

  init(
    id: UUID = UUID(),
    alias: String,
    role: LocalAIModelRole,
    sourceKind: LocalAIModelSourceKind = .localFolder,
    path: String,
    sourceURL: String = "",
    notes: String = ""
  ) {
    self.id = id
    self.alias = alias
    self.role = role
    self.sourceKind = sourceKind
    self.path = path
    self.sourceURL = sourceURL
    self.notes = notes
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case alias
    case role
    case sourceKind
    case path
    case sourceURL
    case notes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    alias = try container.decodeIfPresent(String.self, forKey: .alias) ?? ""
    role = try container.decodeIfPresent(LocalAIModelRole.self, forKey: .role) ?? .chat
    sourceKind = try container.decodeIfPresent(LocalAIModelSourceKind.self, forKey: .sourceKind) ?? .localFolder
    path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
    sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
    notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(alias, forKey: .alias)
    try container.encode(role, forKey: .role)
    try container.encode(sourceKind, forKey: .sourceKind)
    try container.encode(path, forKey: .path)
    try container.encode(sourceURL, forKey: .sourceURL)
    try container.encode(notes, forKey: .notes)
  }

  var trimmedAlias: String {
    alias.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedPath: String {
    path.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedSourceURL: String {
    sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var expandedPath: String {
    NSString(string: trimmedPath).expandingTildeInPath
  }

  var spec: LocalAIModelSpec {
    LocalAIModelSpec(alias: trimmedAlias, path: trimmedPath, role: role)
  }

  var existsOnDisk: Bool {
    spec.existsOnDisk
  }
}

struct LocalAIModelDownloadLink: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let description: String
  let url: String
  let repo: String
  let suggestedAlias: String
  let suggestedFolderName: String
  let role: LocalAIModelRole

  static let recommended: [LocalAIModelDownloadLink] = [
    LocalAIModelDownloadLink(
      id: "qwen3-0.6b-4bit",
      title: "Qwen3 0.6B 4-bit MLX",
      description: "Small chat model used by the headless E2E path.",
      url: "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit",
      repo: "mlx-community/Qwen3-0.6B-4bit",
      suggestedAlias: "qwen3:0.6b",
      suggestedFolderName: "qwen3-0.6b-4bit",
      role: .chat
    ),
    LocalAIModelDownloadLink(
      id: "mlx-community-search",
      title: "MLX Community Models",
      description: "Browse MLX-format chat and embedding model folders.",
      url: "https://huggingface.co/mlx-community",
      repo: "mlx-community/Qwen3-0.6B-4bit",
      suggestedAlias: "my-mlx-model",
      suggestedFolderName: "my-mlx-model",
      role: .chat
    ),
    LocalAIModelDownloadLink(
      id: "mlx-embedding-search",
      title: "MLX Embedding Models",
      description: "Search for MLX embedding models and set them as embedding rows.",
      url: "https://huggingface.co/models?library=mlx&search=embedding",
      repo: "",
      suggestedAlias: "local-embedding",
      suggestedFolderName: "local-embedding",
      role: .embedding
    ),
  ]
}

struct LocalAIModelSpec: Codable, Hashable, Sendable {
  let alias: String
  let path: String
  let role: LocalAIModelRole

  var isConfigured: Bool {
    !alias.isEmpty && !path.isEmpty
  }

  var existsOnDisk: Bool {
    guard isConfigured else { return false }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  var expandedPath: String {
    NSString(string: path).expandingTildeInPath
  }
}

struct LocalAIModelListEntry: Encodable, Sendable {
  let id: String
  let object: String
  let created: Int
  let ownedBy: String

  enum CodingKeys: String, CodingKey {
    case id
    case object
    case created
    case ownedBy = "owned_by"
  }
}

struct LocalAIValidationResult: Hashable, Sendable {
  let role: LocalAIModelRole
  let alias: String
  let path: String
  let isUsable: Bool
  let message: String
}

struct LocalAIChatMessage: Codable, Hashable, Sendable {
  let role: String
  let content: String
}

struct LocalAIChatTurn: Identifiable, Hashable, Sendable {
  let id: UUID
  let role: String
  let content: String
  let model: String?
  let createdAt: Date

  init(id: UUID = UUID(), role: String, content: String, model: String? = nil, createdAt: Date = Date()) {
    self.id = id
    self.role = role
    self.content = content
    self.model = model
    self.createdAt = createdAt
  }
}

struct LocalAIChatRequest: Sendable {
  let model: String
  let messages: [LocalAIChatMessage]
  let stream: Bool
  let temperature: Double?
  let topP: Double?
  let maxTokens: Int?
  let stop: [String]?
}

struct LocalAIChatResult: Sendable {
  let content: String
  let promptTokens: Int
  let completionTokens: Int
  let finishReason: String
}

struct LocalAIEmbeddingRequest: Sendable {
  let model: String
  let input: [String]
}

struct LocalAIEmbeddingResult: Sendable {
  let embeddings: [[Float]]
  let promptTokens: Int
}

struct LocalAIProcessResult: Sendable {
  let exitCode: Int32
  let stdout: String
  let stderr: String
}

enum LocalAIError: LocalizedError, Sendable {
  case invalidRequest(String, param: String? = nil, code: String = "invalid_request")
  case unsupportedParameter(String)
  case modelNotConfigured(String)
  case modelNotFound(String)
  case modelLoadFailed(String)
  case runtimeBusy
  case runtimeFailed(String)
  case unauthorized
  case notFound(String)

  var errorDescription: String? {
    switch self {
    case .invalidRequest(let message, _, _):
      message
    case .unsupportedParameter(let name):
      "Unsupported parameter: \(name)"
    case .modelNotConfigured(let model):
      "Model '\(model)' is not configured"
    case .modelNotFound(let model):
      "Model '\(model)' was not found on disk"
    case .modelLoadFailed(let message):
      message
    case .runtimeBusy:
      "Runtime is busy"
    case .runtimeFailed(let message):
      message
    case .unauthorized:
      "Missing or invalid API key"
    case .notFound(let path):
      "Endpoint not found: \(path)"
    }
  }

  var httpStatus: Int {
    switch self {
    case .invalidRequest, .unsupportedParameter, .modelNotConfigured, .modelNotFound, .modelLoadFailed:
      400
    case .unauthorized:
      401
    case .runtimeBusy:
      429
    case .runtimeFailed:
      500
    case .notFound:
      404
    }
  }

  var type: String {
    switch self {
    case .runtimeBusy:
      "rate_limit_error"
    case .runtimeFailed, .modelLoadFailed:
      "server_error"
    default:
      "invalid_request_error"
    }
  }

  var param: String? {
    switch self {
    case .invalidRequest(_, let param, _):
      param
    case .unsupportedParameter:
      "unsupported_parameter"
    case .modelNotConfigured, .modelNotFound, .modelLoadFailed:
      "model"
    default:
      nil
    }
  }

  var code: String {
    switch self {
    case .invalidRequest(_, _, let code):
      code
    case .unsupportedParameter:
      "unsupported_parameter"
    case .modelNotConfigured:
      "model_not_configured"
    case .modelNotFound:
      "model_not_found"
    case .modelLoadFailed:
      "model_load_failed"
    case .runtimeBusy:
      "runtime_busy"
    case .runtimeFailed:
      "runtime_failed"
    case .unauthorized:
      "unauthorized"
    case .notFound:
      "not_found"
    }
  }
}

extension LocalAIError {
  func openAIErrorData() -> Data {
    let object: [String: Any] = [
      "error": [
        "message": errorDescription ?? "Unknown error",
        "type": type,
        "param": param.map { $0 as Any } ?? NSNull(),
        "code": code,
      ]
    ]
    return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
  }
}

enum LocalAIJSON {
  static func data(_ object: Any, pretty: Bool = false) -> Data {
    let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : []
    return (try? JSONSerialization.data(withJSONObject: object, options: options)) ?? Data("{}".utf8)
  }

  static func string(_ object: Any, pretty: Bool = false) -> String {
    String(data: data(object, pretty: pretty), encoding: .utf8) ?? "{}"
  }
}

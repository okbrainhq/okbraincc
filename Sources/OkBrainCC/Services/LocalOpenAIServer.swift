import Darwin
import Foundation

final class LocalOpenAIServer: @unchecked Sendable {
  private let settings: LocalAISettings
  private let runtime: any LocalAIRuntime
  private let logHandler: (@Sendable (String) -> Void)?
  private let acceptQueue = DispatchQueue(label: "okbraincc.local-ai.accept", qos: .userInitiated)
  private let connectionQueue = DispatchQueue(label: "okbraincc.local-ai.connection", qos: .userInitiated, attributes: .concurrent)
  private var listenFD: Int32 = -1
  private var running = false

  init(settings: LocalAISettings, runtime: any LocalAIRuntime, logHandler: (@Sendable (String) -> Void)? = nil) {
    self.settings = settings
    self.runtime = runtime
    self.logHandler = logHandler
  }

  var isRunning: Bool {
    running
  }

  func start() throws {
    guard !running else { return }

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw LocalAIError.runtimeFailed("socket() failed: \(String(cString: strerror(errno)))")
    }

    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(settings.port).bigEndian)

    let host = settings.trimmedHost.isEmpty ? LocalAISettings.defaults.host : settings.trimmedHost
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
      close(fd)
      throw LocalAIError.runtimeFailed("Only IPv4 bind hosts are supported by the headless server right now. Use 127.0.0.1 for local mode.")
    }

    let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }

    guard bindResult == 0 else {
      let message = String(cString: strerror(errno))
      close(fd)
      throw LocalAIError.runtimeFailed("bind(\(host):\(settings.port)) failed: \(message)")
    }

    guard listen(fd, SOMAXCONN) == 0 else {
      let message = String(cString: strerror(errno))
      close(fd)
      throw LocalAIError.runtimeFailed("listen() failed: \(message)")
    }

    listenFD = fd
    running = true
    log("Local OpenAI API listening on \(settings.baseURL)")

    acceptQueue.async { [weak self] in
      self?.acceptLoop()
    }
  }

  func stop() {
    guard running else { return }
    running = false
    if listenFD >= 0 {
      shutdown(listenFD, SHUT_RDWR)
      close(listenFD)
      listenFD = -1
    }
    log("Local OpenAI API stopped")
  }

  private func acceptLoop() {
    while running {
      var clientAddress = sockaddr_storage()
      var clientLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
          accept(listenFD, sockaddrPointer, &clientLength)
        }
      }

      if clientFD < 0 {
        if running {
          log("accept() failed: \(String(cString: strerror(errno)))")
        }
        continue
      }

      connectionQueue.async { [weak self] in
        self?.handleConnection(clientFD)
      }
    }
  }

  private func handleConnection(_ fd: Int32) {
    defer { close(fd) }

    do {
      let request = try readRequest(from: fd)
      log("\(request.method) \(request.path)")

      if isStreamingChatRequest(request) {
        try authorize(request)
        try writeStreamingChatResponse(request, to: fd)
      } else {
        let response = try route(request)
        try writeResponse(response, to: fd)
      }
    } catch let error as LocalAIError {
      let response = HTTPResponse(
        statusCode: error.httpStatus,
        reason: HTTPResponse.reasonPhrase(for: error.httpStatus),
        headers: ["Content-Type": "application/json"],
        body: error.openAIErrorData()
      )
      try? writeResponse(response, to: fd)
      log("error \(error.httpStatus): \(error.errorDescription ?? String(describing: error))")
    } catch {
      let apiError = LocalAIError.runtimeFailed(error.localizedDescription)
      let response = HTTPResponse(
        statusCode: apiError.httpStatus,
        reason: HTTPResponse.reasonPhrase(for: apiError.httpStatus),
        headers: ["Content-Type": "application/json"],
        body: apiError.openAIErrorData()
      )
      try? writeResponse(response, to: fd)
      log("error 500: \(error.localizedDescription)")
    }
  }

  private func route(_ request: HTTPRequest) throws -> HTTPResponse {
    try authorize(request)

    switch (request.method, request.pathOnly) {
    case ("GET", "/health"):
      return jsonResponse([
        "status": "ok",
        "object": "okbraincc.local_ai.health",
        "base_url": settings.baseURL,
        "runtime": settings.runtimeKind.rawValue,
      ])

    case ("GET", "/v1/models"):
      return jsonResponse(modelsResponse())

    case ("POST", "/v1/chat/completions"):
      let chatRequest = try parseChatCompletionRequest(request.body)
      let result = try runBlocking {
        try await self.runtime.completeChat(chatRequest, settings: self.settings)
      }
      return jsonResponse(chatCompletionResponse(for: chatRequest, result: result))

    case ("POST", "/v1/embeddings"):
      let embeddingRequest = try parseEmbeddingRequest(request.body)
      let result = try runBlocking {
        try await self.runtime.embed(embeddingRequest, settings: self.settings)
      }
      return jsonResponse(embeddingResponse(for: embeddingRequest, result: result))

    default:
      throw LocalAIError.notFound(request.pathOnly)
    }
  }

  private func writeStreamingChatResponse(_ request: HTTPRequest, to fd: Int32) throws {
    guard request.pathOnly == "/v1/chat/completions", request.method == "POST" else {
      let response = try route(request)
      try writeResponse(response, to: fd)
      return
    }

    let chatRequest = try parseChatCompletionRequest(request.body)
    guard chatRequest.stream else {
      let response = try route(request)
      try writeResponse(response, to: fd)
      return
    }

    let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nConnection: close\r\nX-Accel-Buffering: no\r\n\r\n"
    try writeString(header, to: fd)

    let id = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let created = Int(Date().timeIntervalSince1970)

    try writeSSEChunk([
      "id": id,
      "object": "chat.completion.chunk",
      "created": created,
      "model": chatRequest.model,
      "choices": [[
        "index": 0,
        "delta": ["role": "assistant"],
        "finish_reason": NSNull(),
      ]],
    ], to: fd)

    let chunks = try runBlocking {
      let stream = try await self.runtime.streamChat(chatRequest, settings: self.settings)
      var collected: [String] = []
      for try await chunk in stream {
        collected.append(chunk)
      }
      return collected
    }

    for chunk in chunks {
      try writeSSEChunk([
        "id": id,
        "object": "chat.completion.chunk",
        "created": created,
        "model": chatRequest.model,
        "choices": [[
          "index": 0,
          "delta": ["content": chunk],
          "finish_reason": NSNull(),
        ]],
      ], to: fd)
    }

    try writeSSEChunk([
      "id": id,
      "object": "chat.completion.chunk",
      "created": created,
      "model": chatRequest.model,
      "choices": [[
        "index": 0,
        "delta": [:],
        "finish_reason": "stop",
      ]],
    ], to: fd)
    try writeString("data: [DONE]\n\n", to: fd)
  }

  private func writeSSEChunk(_ object: Any, to fd: Int32) throws {
    let line = "data: \(LocalAIJSON.string(object))\n\n"
    try writeString(line, to: fd)
  }

  private func authorize(_ request: HTTPRequest) throws {
    guard settings.requiresAPIKey else { return }
    let expected = settings.trimmedAPIKey
    guard !expected.isEmpty else { throw LocalAIError.unauthorized }

    let authorization = request.headers["authorization"] ?? ""
    guard authorization == "Bearer \(expected)" else {
      throw LocalAIError.unauthorized
    }
  }

  private func modelsResponse() -> [String: Any] {
    let created = Int(Date().timeIntervalSince1970)
    var data: [[String: Any]] = []
    var seen = Set<String>()

    for role in LocalAIModelRole.allCases {
      for spec in settings.modelSpecs(role: role) {
        let include = settings.runtimeKind == .mock || spec.existsOnDisk
        guard include, seen.insert(spec.alias).inserted else { continue }
        data.append(modelObject(id: spec.alias, created: created))
      }
    }

    return ["object": "list", "data": data]
  }

  private func modelObject(id: String, created: Int) -> [String: Any] {
    [
      "id": id,
      "object": "model",
      "created": created,
      "owned_by": "okbraincc",
    ]
  }

  private func chatCompletionResponse(for request: LocalAIChatRequest, result: LocalAIChatResult) -> [String: Any] {
    let promptTokens = result.promptTokens
    let completionTokens = result.completionTokens
    return [
      "id": "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
      "object": "chat.completion",
      "created": Int(Date().timeIntervalSince1970),
      "model": request.model,
      "choices": [[
        "index": 0,
        "message": [
          "role": "assistant",
          "content": result.content,
        ],
        "finish_reason": result.finishReason,
      ]],
      "usage": [
        "prompt_tokens": promptTokens,
        "completion_tokens": completionTokens,
        "total_tokens": promptTokens + completionTokens,
      ],
    ]
  }

  private func embeddingResponse(for request: LocalAIEmbeddingRequest, result: LocalAIEmbeddingResult) -> [String: Any] {
    [
      "object": "list",
      "data": result.embeddings.enumerated().map { index, vector in
        [
          "object": "embedding",
          "embedding": vector.map(Double.init),
          "index": index,
        ]
      },
      "model": request.model,
      "usage": [
        "prompt_tokens": result.promptTokens,
        "total_tokens": result.promptTokens,
      ],
    ]
  }

  private func parseChatCompletionRequest(_ body: Data) throws -> LocalAIChatRequest {
    guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      throw LocalAIError.invalidRequest("Request body must be a JSON object.")
    }

    if object["tools"] != nil {
      throw LocalAIError.unsupportedParameter("tools")
    }
    if object["tool_choice"] != nil {
      throw LocalAIError.unsupportedParameter("tool_choice")
    }
    if object["response_format"] != nil {
      throw LocalAIError.unsupportedParameter("response_format")
    }

    guard let model = object["model"] as? String, !model.isEmpty else {
      throw LocalAIError.invalidRequest("Missing required field: model", param: "model", code: "missing_required_parameter")
    }

    guard let rawMessages = object["messages"] as? [[String: Any]], !rawMessages.isEmpty else {
      throw LocalAIError.invalidRequest("Missing or invalid required field: messages", param: "messages", code: "invalid_messages")
    }

    let messages = try rawMessages.map { raw -> LocalAIChatMessage in
      guard let role = raw["role"] as? String, !role.isEmpty else {
        throw LocalAIError.invalidRequest("Each message must include a role.", param: "messages", code: "invalid_messages")
      }
      guard let content = raw["content"] as? String else {
        throw LocalAIError.invalidRequest("Only string message content is supported.", param: "messages", code: "invalid_messages")
      }
      return LocalAIChatMessage(role: role, content: content)
    }

    let stop: [String]?
    if let stringStop = object["stop"] as? String {
      stop = [stringStop]
    } else {
      stop = object["stop"] as? [String]
    }

    return LocalAIChatRequest(
      model: model,
      messages: messages,
      stream: object["stream"] as? Bool ?? false,
      temperature: object["temperature"] as? Double,
      topP: object["top_p"] as? Double,
      maxTokens: object["max_tokens"] as? Int,
      stop: stop
    )
  }

  private func parseEmbeddingRequest(_ body: Data) throws -> LocalAIEmbeddingRequest {
    guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      throw LocalAIError.invalidRequest("Request body must be a JSON object.")
    }

    guard let model = object["model"] as? String, !model.isEmpty else {
      throw LocalAIError.invalidRequest("Missing required field: model", param: "model", code: "missing_required_parameter")
    }

    let input: [String]
    if let string = object["input"] as? String {
      input = [string]
    } else if let strings = object["input"] as? [String], !strings.isEmpty {
      input = strings
    } else {
      throw LocalAIError.invalidRequest("Input must be a string or a non-empty array of strings.", param: "input", code: "invalid_input")
    }

    return LocalAIEmbeddingRequest(model: model, input: input)
  }

  private func isStreamingChatRequest(_ request: HTTPRequest) -> Bool {
    guard request.method == "POST", request.pathOnly == "/v1/chat/completions" else { return false }
    guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return false }
    return object["stream"] as? Bool == true
  }

  private func jsonResponse(_ object: Any, statusCode: Int = 200) -> HTTPResponse {
    HTTPResponse(
      statusCode: statusCode,
      reason: HTTPResponse.reasonPhrase(for: statusCode),
      headers: ["Content-Type": "application/json"],
      body: LocalAIJSON.data(object)
    )
  }

  private func readRequest(from fd: Int32) throws -> HTTPRequest {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    let delimiter = Data([13, 10, 13, 10])

    while data.range(of: delimiter) == nil {
      let count = recv(fd, &buffer, buffer.count, 0)
      if count <= 0 {
        throw LocalAIError.invalidRequest("Connection closed before request headers were complete.")
      }
      data.append(buffer, count: count)
      if data.count > 1_048_576 {
        throw LocalAIError.invalidRequest("Request headers are too large.")
      }
    }

    guard let headerRange = data.range(of: delimiter) else {
      throw LocalAIError.invalidRequest("Invalid HTTP request.")
    }

    let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
    guard let headerText = String(data: headerData, encoding: .utf8) else {
      throw LocalAIError.invalidRequest("Request headers must be UTF-8.")
    }

    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      throw LocalAIError.invalidRequest("Missing request line.")
    }

    let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count >= 2 else {
      throw LocalAIError.invalidRequest("Invalid request line.")
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[String(name)] = value
    }

    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    let bodyStart = headerRange.upperBound
    var body = data.subdata(in: bodyStart..<data.endIndex)

    while body.count < contentLength {
      let count = recv(fd, &buffer, min(buffer.count, contentLength - body.count), 0)
      if count <= 0 {
        throw LocalAIError.invalidRequest("Connection closed before request body was complete.")
      }
      body.append(buffer, count: count)
    }

    if body.count > contentLength {
      body = body.subdata(in: 0..<contentLength)
    }

    return HTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body)
  }

  private func writeResponse(_ response: HTTPResponse, to fd: Int32) throws {
    var headers = response.headers
    headers["Content-Length"] = "\(response.body.count)"
    headers["Connection"] = "close"

    var head = "HTTP/1.1 \(response.statusCode) \(response.reason)\r\n"
    for (name, value) in headers {
      head += "\(name): \(value)\r\n"
    }
    head += "\r\n"

    try writeData(Data(head.utf8), to: fd)
    try writeData(response.body, to: fd)
  }

  private func writeString(_ string: String, to fd: Int32) throws {
    try writeData(Data(string.utf8), to: fd)
  }

  private func writeData(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
      var total = 0
      while total < data.count {
        let sent = send(fd, base.advanced(by: total), data.count - total, 0)
        if sent <= 0 {
          throw LocalAIError.runtimeFailed("send() failed: \(String(cString: strerror(errno)))")
        }
        total += sent
      }
    }
  }

  private func runBlocking<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = LocalAIRunBlockingBox<T>()

    Task.detached {
      do {
        box.result = Result<T, Error>.success(try await operation())
      } catch {
        box.result = Result<T, Error>.failure(error)
      }
      semaphore.signal()
    }

    semaphore.wait()
    return try box.result!.get()
  }

  private func log(_ message: String) {
    logHandler?("[LocalAI] \(message)")
  }
}

private final class LocalAIRunBlockingBox<T>: @unchecked Sendable {
  var result: Result<T, Error>?
}

private struct HTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data

  var pathOnly: String {
    path.components(separatedBy: "?").first ?? path
  }
}

private struct HTTPResponse {
  let statusCode: Int
  let reason: String
  let headers: [String: String]
  let body: Data

  static func reasonPhrase(for statusCode: Int) -> String {
    switch statusCode {
    case 200: "OK"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 404: "Not Found"
    case 429: "Too Many Requests"
    case 500: "Internal Server Error"
    default: "OK"
    }
  }
}

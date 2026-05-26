import Foundation

struct BackupPageData {
  let status: BackupSystemStatus
  let restoreDates: [String]
}

struct BackupRunDetails {
  let log: String
  let components: [BackupComponentStatus]
}

enum BackupFilesystemLoader {
  static func loadLatestCompletionDate(for definition: BackupSystemDefinition) -> Date? {
    let runIDs = recentRunIDs(for: definition, limit: 1)
    guard let newestRunID = runIDs.first else {
      return nil
    }

    let newestRunURL = runsDirectoryURL(for: definition).appendingPathComponent(newestRunID, isDirectory: true)
    let newestMetadata = metadata(in: newestRunURL)
    let backupLogTail = tail(of: newestRunURL.appendingPathComponent("backup.log", isDirectory: false))

    return metadataDate("finished_at", in: newestMetadata) ??
      latestCompletionDate(from: backupLogTail) ??
      runDate(from: newestRunID)
  }

  static func loadPageData(for definition: BackupSystemDefinition, limit: Int) -> BackupPageData {
    let runIDs = recentRunIDs(for: definition, limit: limit)
    let newestRunURL = newestRunURL(for: definition, runIDs: runIDs)
    let status = buildStatus(for: definition, newestRunURL: newestRunURL, runIDs: runIDs)

    return BackupPageData(status: status, restoreDates: runIDs)
  }

  static func loadRunDetails(for definition: BackupSystemDefinition, runID: String) -> BackupRunDetails {
    guard runID.range(of: #"[\/]"#, options: .regularExpression) == nil else {
      return BackupRunDetails(log: "Invalid backup run id: \(runID)", components: [])
    }

    let runURL = runsDirectoryURL(for: definition).appendingPathComponent(runID, isDirectory: true)
    guard FileManager.default.fileExists(atPath: runURL.path) else {
      return BackupRunDetails(log: "No backup run found for \(runID).", components: [])
    }

    let runIDs = recentRunIDs(for: definition, limit: 30)
    let log = combinedLog(in: runURL)
    let components = buildComponentStatuses(
      for: definition,
      runURL: runURL,
      runID: runID,
      runIDs: runIDs
    )

    return BackupRunDetails(
      log: log.isEmpty ? "No logs found for \(runID)." : log,
      components: components
    )
  }

  private static func recentRunIDs(for definition: BackupSystemDefinition, limit: Int) -> [String] {
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: runsDirectoryURL(for: definition),
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    return entries
      .compactMap { url in
        guard url.lastPathComponent.hasPrefix("20") else {
          return nil
        }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true ? url.lastPathComponent : nil
      }
      .sorted(by: >)
      .prefix(limit)
      .map { $0 }
  }

  private static func buildStatus(
    for definition: BackupSystemDefinition,
    newestRunURL: URL?,
    runIDs: [String]
  ) -> BackupSystemStatus {
    let backupDirectoryURL = definition.backupDirectoryURL
    let backupDirectoryExists = FileManager.default.fileExists(atPath: backupDirectoryURL.path)
    let newestRunID = newestRunURL?.lastPathComponent
    let newestMetadata = newestRunURL.map { metadata(in: $0) } ?? [:]
    let newestRunSucceeded = newestMetadata["status"] == "success" ||
      (newestRunURL.map { tail(of: $0.appendingPathComponent("backup.log")).contains("completed") } ?? false)

    let componentStatuses = newestRunURL.map {
      buildComponentStatuses(
        for: definition,
        runURL: $0,
        runID: newestRunID,
        runSucceeded: newestRunSucceeded,
        runIDs: runIDs
      )
    } ?? definition.components.map { missingComponentStatus(for: $0, definition: definition) }

    let requiredCurrent = newestRunSucceeded &&
      componentStatuses
        .filter { $0.isRequired }
        .allSatisfy { $0.isCurrentToday }

    let backupLogTail = newestRunURL.map { tail(of: $0.appendingPathComponent("backup.log", isDirectory: false)) } ?? ""
    let stdoutLogTail = newestRunURL.map { tail(of: $0.appendingPathComponent("stdout.log", isDirectory: false)) } ?? ""
    let stderrLogTail = newestRunURL.map { tail(of: $0.appendingPathComponent("stderr.log", isDirectory: false)) } ?? ""

    return BackupSystemStatus(
      systemID: definition.id,
      backupDirectoryPath: backupDirectoryURL.path,
      backupDirectoryExists: backupDirectoryExists,
      requiredComponentsAreCurrent: requiredCurrent,
      latestCompletionDate: metadataDate("finished_at", in: newestMetadata) ??
        latestCompletionDate(from: backupLogTail) ??
        newestRunID.flatMap(runDate),
      components: componentStatuses,
      recentErrors: recentErrors(from: backupLogTail + "\n" + stderrLogTail),
      backupLogTail: backupLogTail,
      stdoutLogTail: stdoutLogTail,
      stderrLogTail: stderrLogTail
    )
  }

  private static func buildComponentStatuses(
    for definition: BackupSystemDefinition,
    runURL: URL,
    runID: String?,
    runSucceeded: Bool? = nil,
    runIDs: [String]
  ) -> [BackupComponentStatus] {
    let metadata = self.metadata(in: runURL)
    let succeeded = runSucceeded ??
      (metadata["status"] == "success" || tail(of: runURL.appendingPathComponent("backup.log")).contains("completed"))
    let today = dayFormatter.string(from: Date())

    return definition.components.map { component in
      let selectedComponentURL = componentURL(for: component, in: runURL)
      let selectedComponentExists = FileManager.default.fileExists(atPath: selectedComponentURL.path)
      let snapshotCount = runIDs.reduce(into: 0) { count, candidateRunID in
        let candidateRunURL = runsDirectoryURL(for: definition)
          .appendingPathComponent(candidateRunID, isDirectory: true)
        let candidateComponentURL = componentURL(for: component, in: candidateRunURL)
        if FileManager.default.fileExists(atPath: candidateComponentURL.path) {
          count += 1
        }
      }

      return BackupComponentStatus(
        id: component.id,
        title: component.title,
        isRequired: component.isRequired,
        latestDate: selectedComponentExists ? runID : nil,
        snapshotCount: snapshotCount,
        size: diskUsage(for: selectedComponentURL),
        isCurrentToday: selectedComponentExists && succeeded && (runID?.hasPrefix(today) == true),
        path: selectedComponentURL.path
      )
    }
  }

  private static func missingComponentStatus(
    for component: BackupComponentDefinition,
    definition: BackupSystemDefinition
  ) -> BackupComponentStatus {
    return BackupComponentStatus(
      id: component.id,
      title: component.title,
      isRequired: component.isRequired,
      latestDate: nil,
      snapshotCount: 0,
      size: "Missing",
      isCurrentToday: false,
      path: definition.backupDirectoryURL.path
    )
  }

  private static func newestRunURL(for definition: BackupSystemDefinition, runIDs: [String]) -> URL? {
    guard let runID = runIDs.first else {
      return nil
    }

    return runsDirectoryURL(for: definition).appendingPathComponent(runID, isDirectory: true)
  }

  private static func runsDirectoryURL(for definition: BackupSystemDefinition) -> URL {
    definition.backupDirectoryURL.appendingPathComponent("runs", isDirectory: true)
  }

  private static func componentURL(for component: BackupComponentDefinition, in runURL: URL) -> URL {
    component.relativePath
      .split(separator: "/")
      .reduce(runURL) { url, component in
        url.appendingPathComponent(String(component), isDirectory: false)
      }
  }

  private static func combinedLog(in runURL: URL) -> String {
    [
      tail(of: runURL.appendingPathComponent("backup.log", isDirectory: false)),
      tail(of: runURL.appendingPathComponent("stdout.log", isDirectory: false)),
      tail(of: runURL.appendingPathComponent("stderr.log", isDirectory: false))
    ]
    .filter { !$0.isEmpty }
    .joined(separator: "\n\n")
  }

  private static func metadata(in runURL: URL) -> [String: String] {
    guard let text = try? String(contentsOf: runURL.appendingPathComponent("metadata.env"), encoding: .utf8) else {
      return [:]
    }

    return text
      .split(separator: "\n")
      .reduce(into: [:]) { result, line in
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
          return
        }

        result[parts[0]] = parts[1]
      }
  }

  private static func metadataDate(_ key: String, in metadata: [String: String]) -> Date? {
    guard let value = metadata[key] else {
      return nil
    }

    return timestampFormatter.date(from: value)
  }

  private static func diskUsage(for url: URL) -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return "Missing"
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    process.arguments = ["-sh", url.path]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let text = String(decoding: data, as: UTF8.self)
      return text.split(separator: "\t").first.map(String.init) ?? "Unknown"
    } catch {
      return "Unknown"
    }
  }

  private static func tail(of url: URL, maxBytes: UInt64 = 60_000) -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return ""
    }

    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
      let handle = try FileHandle(forReadingFrom: url)
      defer {
        try? handle.close()
      }

      if fileSize > maxBytes {
        try handle.seek(toOffset: fileSize - maxBytes)
      }

      let data = try handle.readToEnd() ?? Data()
      return String(decoding: data, as: UTF8.self)
    } catch {
      return ""
    }
  }

  private static func latestCompletionDate(from log: String) -> Date? {
    var latestDate: Date?

    for line in log.split(separator: "\n") {
      guard line.contains("=== Backup completed") || line.contains("=== Prodbox sandbox backup completed") else {
        continue
      }

      if let date = timestamp(from: String(line)) {
        latestDate = date
      }
    }

    return latestDate
  }

  private static func recentErrors(from log: String) -> [String] {
    let needles = ["error", "failed", "permission denied"]
    return log
      .split(separator: "\n")
      .map(String.init)
      .filter { line in
        let lowercased = line.lowercased()
        return needles.contains { lowercased.contains($0) }
      }
      .suffix(6)
      .map { $0 }
  }

  private static func timestamp(from line: String) -> Date? {
    guard line.hasPrefix("["), line.count >= 21 else {
      return nil
    }

    let timestampStart = line.index(after: line.startIndex)
    let timestampEnd = line.index(timestampStart, offsetBy: 19, limitedBy: line.endIndex) ?? line.endIndex
    return timestampFormatter.date(from: String(line[timestampStart..<timestampEnd]))
  }

  private static func runDate(from runID: String) -> Date? {
    guard runID.count >= 15 else {
      return nil
    }

    let timestampEnd = runID.index(runID.startIndex, offsetBy: 15)
    return runIDFormatter.date(from: String(runID[..<timestampEnd]))
  }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()

  private static let runIDFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    return formatter
  }()
}

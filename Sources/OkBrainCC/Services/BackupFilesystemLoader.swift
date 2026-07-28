import Foundation

struct BackupPageData {
  let status: BackupSystemStatus
  let restoreDates: [String]
  let restoreRuns: [BackupRun]
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

    if let manifest = loadManifest(for: definition, runID: newestRunID) {
      return timestampFormatter.date(from: manifest.finishedAt) ?? runDate(from: newestRunID)
    }

    // Legacy directory fallback
    let newestRunURL = runsDirectoryURL(for: definition).appendingPathComponent(newestRunID, isDirectory: true)
    let newestMetadata = legacyMetadata(in: newestRunURL)
    let backupLogTail = legacyTail(of: newestRunURL.appendingPathComponent("backup.log", isDirectory: false))

    return legacyMetadataDate("finished_at", in: newestMetadata) ??
      latestCompletionDate(from: backupLogTail) ??
      runDate(from: newestRunID)
  }

  static func loadPageData(for definition: BackupSystemDefinition, limit: Int) -> BackupPageData {
    let runIDs = recentRunIDs(for: definition, limit: limit)
    let status = buildStatus(for: definition, runIDs: runIDs)
    let restoreRuns = recentRestoreRuns(for: definition, limit: limit)

    return BackupPageData(status: status, restoreDates: runIDs, restoreRuns: restoreRuns)
  }

  static func loadRunDetails(for definition: BackupSystemDefinition, runID: String) -> BackupRunDetails {
    guard runID.range(of: #"[/]"#, options: .regularExpression) == nil else {
      return BackupRunDetails(log: "Invalid backup run id: \(runID)", components: [])
    }

    if let manifest = loadManifest(for: definition, runID: runID) {
      let log = [
        manifest.backupLogTail,
        manifest.stdoutLogTail,
        manifest.stderrLogTail
      ]
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")

      let runIDs = recentRunIDs(for: definition, limit: 30)
      let components = manifestComponentStatuses(
        for: definition,
        manifest: manifest,
        runID: runID,
        runIDs: runIDs
      )

      return BackupRunDetails(
        log: log.isEmpty ? "No logs found for \(runID)." : log,
        components: components
      )
    }

    // Legacy directory fallback
    let runURL = runsDirectoryURL(for: definition).appendingPathComponent(runID, isDirectory: true)
    guard FileManager.default.fileExists(atPath: runURL.path) else {
      return BackupRunDetails(log: "No backup run found for \(runID).", components: [])
    }

    let runIDs = recentRunIDs(for: definition, limit: 30)
    let log = legacyCombinedLog(in: runURL)
    let components = legacyBuildComponentStatuses(
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

  // MARK: - Run ID Discovery

  private static func recentRunIDs(for definition: BackupSystemDefinition, limit: Int) -> [String] {
    let runsURL = runsDirectoryURL(for: definition)
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: runsURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    var runIDs = Set<String>()

    for url in entries {
      let name = url.lastPathComponent
      guard name.hasPrefix("20") else { continue }

      // Manifest files: 2026-07-28-0330.manifest.json
      if name.hasSuffix(".manifest.json") {
        let runID = String(name.dropLast(".manifest.json".count))
        runIDs.insert(runID)
        continue
      }

      // Zip files: 2026-07-28-0330.zip (covers zip-without-manifest edge case)
      if name.hasSuffix(".zip") {
        let runID = String(name.dropLast(".zip".count))
        runIDs.insert(runID)
        continue
      }

      // Legacy directories: 2026-07-28-0330/
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
      if values?.isDirectory == true {
        runIDs.insert(name)
      }
    }

    return runIDs
      .sorted(by: >)
      .prefix(limit)
      .map { $0 }
  }

  // MARK: - Manifest Loading

  private static func loadManifest(for definition: BackupSystemDefinition, runID: String) -> BackupManifest? {
    let manifestURL = runsDirectoryURL(for: definition)
      .appendingPathComponent("\(runID).manifest.json", isDirectory: false)

    guard let data = try? Data(contentsOf: manifestURL) else {
      return nil
    }

    return try? manifestDecoder.decode(BackupManifest.self, from: data)
  }

  // MARK: - Status Building

  private static func buildStatus(
    for definition: BackupSystemDefinition,
    runIDs: [String]
  ) -> BackupSystemStatus {
    let backupDirectoryURL = definition.backupDirectoryURL
    let backupDirectoryExists = FileManager.default.fileExists(atPath: backupDirectoryURL.path)

    guard let newestRunID = runIDs.first else {
      return BackupSystemStatus(
        systemID: definition.id,
        backupDirectoryPath: backupDirectoryURL.path,
        backupDirectoryExists: backupDirectoryExists,
        requiredComponentsAreCurrent: false,
        latestCompletionDate: nil,
        components: definition.components.map { missingComponentStatus(for: $0, definition: definition) },
        recentErrors: [],
        backupLogTail: "",
        stdoutLogTail: "",
        stderrLogTail: ""
      )
    }

    if let manifest = loadManifest(for: definition, runID: newestRunID) {
      return buildStatusFromManifest(
        for: definition,
        manifest: manifest,
        runID: newestRunID,
        runIDs: runIDs,
        backupDirectoryURL: backupDirectoryURL,
        backupDirectoryExists: backupDirectoryExists
      )
    }

    // Legacy directory fallback
    let newestRunURL = runsDirectoryURL(for: definition).appendingPathComponent(newestRunID, isDirectory: true)
    return legacyBuildStatus(
      for: definition,
      newestRunURL: newestRunURL,
      newestRunID: newestRunID,
      runIDs: runIDs,
      backupDirectoryURL: backupDirectoryURL,
      backupDirectoryExists: backupDirectoryExists
    )
  }

  private static func buildStatusFromManifest(
    for definition: BackupSystemDefinition,
    manifest: BackupManifest,
    runID: String,
    runIDs: [String],
    backupDirectoryURL: URL,
    backupDirectoryExists: Bool
  ) -> BackupSystemStatus {
    let componentStatuses = manifestComponentStatuses(
      for: definition,
      manifest: manifest,
      runID: runID,
      runIDs: runIDs
    )

    let requiredCurrent = manifest.isSuccess &&
      componentStatuses
        .filter { $0.isRequired }
        .allSatisfy { $0.isCurrentToday }

    let logTail = manifest.backupLogTail
    let stderrTail = manifest.stderrLogTail

    return BackupSystemStatus(
      systemID: definition.id,
      backupDirectoryPath: backupDirectoryURL.path,
      backupDirectoryExists: backupDirectoryExists,
      requiredComponentsAreCurrent: requiredCurrent,
      latestCompletionDate: timestampFormatter.date(from: manifest.finishedAt) ?? runDate(from: runID),
      components: componentStatuses,
      recentErrors: recentErrors(from: logTail + "\n" + stderrTail),
      backupLogTail: logTail,
      stdoutLogTail: manifest.stdoutLogTail,
      stderrLogTail: stderrTail
    )
  }

  private static func manifestComponentStatuses(
    for definition: BackupSystemDefinition,
    manifest: BackupManifest,
    runID: String,
    runIDs: [String]
  ) -> [BackupComponentStatus] {
    let today = dayFormatter.string(from: Date())
    let manifestComponentsByID = Dictionary(uniqueKeysWithValues: manifest.components.map { ($0.id, $0) })

    return definition.components.map { component in
      let manifestComponent = manifestComponentsByID[component.id]
      let exists = manifestComponent?.exists ?? false

      let snapshotCount = runIDs.reduce(into: 0) { count, candidateRunID in
        if let candidateManifest = loadManifest(for: definition, runID: candidateRunID) {
          if candidateManifest.components.first(where: { $0.id == component.id })?.exists == true {
            count += 1
          }
        } else {
          // Legacy fallback: check directory
          let candidateRunURL = runsDirectoryURL(for: definition)
            .appendingPathComponent(candidateRunID, isDirectory: true)
          let candidateComponentURL = componentURL(for: component, in: candidateRunURL)
          if FileManager.default.fileExists(atPath: candidateComponentURL.path) {
            count += 1
          }
        }
      }

      let zipPath = runsDirectoryURL(for: definition)
        .appendingPathComponent("\(runID).zip", isDirectory: false)
        .path

      return BackupComponentStatus(
        id: component.id,
        title: component.title,
        isRequired: component.isRequired,
        latestDate: exists ? runID : nil,
        snapshotCount: snapshotCount,
        size: manifestComponent?.size ?? "Missing",
        isCurrentToday: exists && manifest.isSuccess && runID.hasPrefix(today),
        path: zipPath
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

  // MARK: - Restore Runs

  private static func recentRestoreRuns(for definition: BackupSystemDefinition, limit: Int) -> [BackupRun] {
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: definition.restoreHistoryDirectoryURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    return entries
      .filter { $0.pathExtension == "json" }
      .compactMap { url -> BackupRun? in
        guard
          let data = try? Data(contentsOf: url),
          var run = try? restoreRunDecoder.decode(BackupRun.self, from: data),
          run.systemID == definition.id,
          run.operation == .restore
        else {
          return nil
        }

        if run.status == .running {
          run.status = .stopped
          run.finishedAt = run.finishedAt ?? run.startedAt
          run.log.append("\nRestore was still marked running when the app loaded this saved session.\n")
        }

        return run
      }
      .sorted { $0.startedAt > $1.startedAt }
      .prefix(limit)
      .map { $0 }
  }

  // MARK: - Legacy Directory Support

  private static func legacyBuildStatus(
    for definition: BackupSystemDefinition,
    newestRunURL: URL,
    newestRunID: String,
    runIDs: [String],
    backupDirectoryURL: URL,
    backupDirectoryExists: Bool
  ) -> BackupSystemStatus {
    let newestMetadata = legacyMetadata(in: newestRunURL)
    let newestRunSucceeded = newestMetadata["status"] == "success" ||
      legacyTail(of: newestRunURL.appendingPathComponent("backup.log")).contains("completed")

    let componentStatuses = legacyBuildComponentStatuses(
      for: definition,
      runURL: newestRunURL,
      runID: newestRunID,
      runSucceeded: newestRunSucceeded,
      runIDs: runIDs
    )

    let requiredCurrent = newestRunSucceeded &&
      componentStatuses
        .filter { $0.isRequired }
        .allSatisfy { $0.isCurrentToday }

    let backupLogTail = legacyTail(of: newestRunURL.appendingPathComponent("backup.log", isDirectory: false))
    let stdoutLogTail = legacyTail(of: newestRunURL.appendingPathComponent("stdout.log", isDirectory: false))
    let stderrLogTail = legacyTail(of: newestRunURL.appendingPathComponent("stderr.log", isDirectory: false))

    return BackupSystemStatus(
      systemID: definition.id,
      backupDirectoryPath: backupDirectoryURL.path,
      backupDirectoryExists: backupDirectoryExists,
      requiredComponentsAreCurrent: requiredCurrent,
      latestCompletionDate: legacyMetadataDate("finished_at", in: newestMetadata) ??
        latestCompletionDate(from: backupLogTail) ??
        runDate(from: newestRunID),
      components: componentStatuses,
      recentErrors: recentErrors(from: backupLogTail + "\n" + stderrLogTail),
      backupLogTail: backupLogTail,
      stdoutLogTail: stdoutLogTail,
      stderrLogTail: stderrLogTail
    )
  }

  private static func legacyBuildComponentStatuses(
    for definition: BackupSystemDefinition,
    runURL: URL,
    runID: String,
    runSucceeded: Bool? = nil,
    runIDs: [String]
  ) -> [BackupComponentStatus] {
    let metadata = legacyMetadata(in: runURL)
    let succeeded = runSucceeded ??
      (metadata["status"] == "success" || legacyTail(of: runURL.appendingPathComponent("backup.log")).contains("completed"))
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
        size: legacyDiskUsage(for: selectedComponentURL),
        isCurrentToday: selectedComponentExists && succeeded && runID.hasPrefix(today),
        path: selectedComponentURL.path
      )
    }
  }

  private static func legacyCombinedLog(in runURL: URL) -> String {
    [
      legacyTail(of: runURL.appendingPathComponent("backup.log", isDirectory: false)),
      legacyTail(of: runURL.appendingPathComponent("stdout.log", isDirectory: false)),
      legacyTail(of: runURL.appendingPathComponent("stderr.log", isDirectory: false))
    ]
    .filter { !$0.isEmpty }
    .joined(separator: "\n\n")
  }

  private static func legacyMetadata(in runURL: URL) -> [String: String] {
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

  private static func legacyMetadataDate(_ key: String, in metadata: [String: String]) -> Date? {
    guard let value = metadata[key] else {
      return nil
    }

    return timestampFormatter.date(from: value)
  }

  private static func legacyDiskUsage(for url: URL) -> String {
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

  private static func legacyTail(of url: URL, maxBytes: UInt64 = 60_000) -> String {
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

  // MARK: - Shared Helpers

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

  private static let restoreRunDecoder = JSONDecoder()

  private static let manifestDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    return decoder
  }()
}

import Foundation

struct BackupPageData {
  let status: BackupSystemStatus
  let restoreDates: [String]
  let runs: [BackupRun]?
}

enum BackupFilesystemLoader {
  static func loadPageData(for definition: BackupSystemDefinition, historyURL: URL?) -> BackupPageData {
    let restoreDates = recentRestoreDates(for: definition, limit: 30)
    let status = buildStatus(for: definition)
    let runs = historyURL.map(loadRuns)

    return BackupPageData(status: status, restoreDates: restoreDates, runs: runs)
  }

  private static func recentRestoreDates(for definition: BackupSystemDefinition, limit: Int) -> [String] {
    var dates = Set<String>()
    let backupDirectoryURL = definition.backupDirectoryURL

    for component in definition.components {
      let componentURL = backupDirectoryURL.appendingPathComponent(component.relativePath, isDirectory: true)

      switch component.kind {
      case .directory:
        directorySnapshotNames(in: componentURL).forEach { dates.insert($0) }
      case .database(let prefix, let suffix):
        databaseSnapshotNames(in: componentURL, prefix: prefix, suffix: suffix).forEach { dates.insert($0) }
      }
    }

    return Array(dates).sorted(by: >).prefix(limit).map { $0 }
  }

  private static func buildStatus(for definition: BackupSystemDefinition) -> BackupSystemStatus {
    let backupDirectoryURL = definition.backupDirectoryURL
    let backupDirectoryExists = FileManager.default.fileExists(atPath: backupDirectoryURL.path)
    let today = dayFormatter.string(from: Date())

    let componentStatuses = definition.components.map { component in
      buildComponentStatus(component, backupDirectoryURL: backupDirectoryURL, today: today)
    }

    let requiredCurrent = componentStatuses
      .filter { $0.isRequired }
      .allSatisfy { $0.isCurrentToday }

    let backupLogTail = tail(of: backupDirectoryURL.appendingPathComponent("backup.log", isDirectory: false))
    let stdoutLogTail = tail(of: backupDirectoryURL.appendingPathComponent("backup-stdout.log", isDirectory: false))
    let stderrLogTail = tail(of: backupDirectoryURL.appendingPathComponent("backup-stderr.log", isDirectory: false))

    return BackupSystemStatus(
      systemID: definition.id,
      backupDirectoryPath: backupDirectoryURL.path,
      backupDirectoryExists: backupDirectoryExists,
      requiredComponentsAreCurrent: requiredCurrent,
      latestCompletionDate: latestCompletionDate(from: backupLogTail),
      components: componentStatuses,
      recentErrors: recentErrors(from: backupLogTail + "\n" + stderrLogTail),
      backupLogTail: backupLogTail,
      stdoutLogTail: stdoutLogTail,
      stderrLogTail: stderrLogTail
    )
  }

  private static func buildComponentStatus(
    _ component: BackupComponentDefinition,
    backupDirectoryURL: URL,
    today: String
  ) -> BackupComponentStatus {
    let componentURL = backupDirectoryURL.appendingPathComponent(component.relativePath, isDirectory: true)
    let latestDate: String?
    let snapshotCount: Int
    let isCurrentToday: Bool
    let sizeURL: URL?

    switch component.kind {
    case .directory:
      let snapshotNames = directorySnapshotNames(in: componentURL)
      latestDate = latestSymlinkDate(in: componentURL) ?? snapshotNames.sorted().last
      snapshotCount = snapshotNames.count
      isCurrentToday = latestDate == today
      sizeURL = latestDate.map { componentURL.appendingPathComponent($0, isDirectory: true) }
    case .database(let prefix, let suffix):
      let snapshotNames = databaseSnapshotNames(in: componentURL, prefix: prefix, suffix: suffix)
      latestDate = snapshotNames.sorted().last
      snapshotCount = snapshotNames.count
      isCurrentToday = snapshotNames.contains(today)
      sizeURL = latestDate.map { componentURL.appendingPathComponent("\(prefix)\($0)\(suffix)", isDirectory: false) }
    }

    return BackupComponentStatus(
      id: component.id,
      title: component.title,
      isRequired: component.isRequired,
      latestDate: latestDate,
      snapshotCount: snapshotCount,
      size: sizeURL.map(diskUsage) ?? "Missing",
      isCurrentToday: isCurrentToday,
      path: componentURL.path
    )
  }

  private static func latestSymlinkDate(in componentURL: URL) -> String? {
    let latestURL = componentURL.appendingPathComponent("latest", isDirectory: false)
    guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: latestURL.path) else {
      return nil
    }

    return URL(fileURLWithPath: destination).lastPathComponent
  }

  private static func directorySnapshotNames(in componentURL: URL) -> [String] {
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: componentURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    return entries.compactMap { url in
      guard url.lastPathComponent.hasPrefix("20") else {
        return nil
      }

      let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
      return values?.isDirectory == true ? url.lastPathComponent : nil
    }
  }

  private static func databaseSnapshotNames(in componentURL: URL, prefix: String, suffix: String) -> [String] {
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: componentURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    return entries.compactMap { url in
      let name = url.lastPathComponent
      guard name.hasPrefix(prefix), name.hasSuffix(suffix) else {
        return nil
      }

      let start = name.index(name.startIndex, offsetBy: prefix.count)
      let end = name.index(name.endIndex, offsetBy: -suffix.count)
      return String(name[start..<end])
    }
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
      guard line.contains("=== Backup completed ===") || line.contains("=== Prodbox sandbox backup completed ===") else {
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

  private static func loadRuns(from url: URL) -> [BackupRun] {
    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode([BackupRun].self, from: data)
    } catch {
      return []
    }
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
}

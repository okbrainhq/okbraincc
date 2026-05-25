import AppKit
import Combine
import Foundation

@MainActor
final class BackupAgentStore: ObservableObject {
  static let shared = BackupAgentStore()

  @Published private(set) var runs: [BackupRun] = []
  @Published private(set) var statuses: [BackupSystemID: BackupSystemStatus] = [:]
  @Published private(set) var activeRuns: [BackupSystemID: BackupRun.ID] = [:]
  @Published private(set) var schedules: [BackupSystemID: BackupScheduleSettings] = [:]

  private let historyURL: URL
  private let defaults = UserDefaults.standard
  private let isMockMode: Bool
  private var scheduler: Timer?
  private var activeProcesses: [BackupRun.ID: Process] = [:]
  private var stoppedRunIDs = Set<BackupRun.ID>()

  private init() {
    let supportDirectory = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/OkBrainCC/BackupAgent", isDirectory: true)
    historyURL = supportDirectory.appendingPathComponent("run-history.json", isDirectory: false)
    isMockMode = Self.detectMockMode()
    schedules = Self.loadSchedules(defaults: defaults)
    runs = isMockMode ? Self.mockRuns() : Self.loadRuns(from: historyURL)
    if isMockMode {
      activeRuns = Dictionary(uniqueKeysWithValues: runs.compactMap { run in
        run.status == .running ? (run.systemID, run.id) : nil
      })
    }
    refreshStatuses()
  }

  func startScheduler() {
    guard scheduler == nil else {
      return
    }

    refreshStatuses()
    evaluateAutomaticBackups()

    let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.evaluateAutomaticBackups()
      }
    }
    timer.tolerance = 10
    scheduler = timer
  }

  func refreshStatuses() {
    var nextStatuses: [BackupSystemID: BackupSystemStatus] = [:]
    for definition in BackupSystemDefinition.all {
      nextStatuses[definition.id] = buildStatus(for: definition)
    }
    importObservedRuns(from: nextStatuses)
    statuses = nextStatuses
  }

  func status(for systemID: BackupSystemID) -> BackupSystemStatus? {
    statuses[systemID]
  }

  func activeRunID(for systemID: BackupSystemID) -> BackupRun.ID? {
    activeRuns[systemID]
  }

  func runs(for systemID: BackupSystemID) -> [BackupRun] {
    runs.filter { $0.systemID == systemID }
  }

  func run(with id: BackupRun.ID?) -> BackupRun? {
    guard let id else {
      return nil
    }

    return runs.first { $0.id == id }
  }

  func schedule(for systemID: BackupSystemID) -> BackupScheduleSettings {
    schedules[systemID] ?? Self.defaultSchedule(for: systemID, defaults: defaults)
  }

  func updateSchedule(systemID: BackupSystemID, isEnabled: Bool? = nil, hour: Int? = nil, minute: Int? = nil) {
    let current = schedule(for: systemID)
    let next = BackupScheduleSettings(
      isEnabled: isEnabled ?? current.isEnabled,
      hour: min(max(hour ?? current.hour, 0), 23),
      minute: min(max(minute ?? current.minute, 0), 59)
    )

    defaults.set(next.isEnabled, forKey: Self.scheduleEnabledKey(for: systemID))
    defaults.set(next.hour, forKey: Self.scheduleHourKey(for: systemID))
    defaults.set(next.minute, forKey: Self.scheduleMinuteKey(for: systemID))
    schedules[systemID] = next
  }

  @discardableResult
  func runBackup(systemID: BackupSystemID, trigger: BackupRunTrigger = .manual) -> BackupRun.ID? {
    if isMockMode {
      return runMockOperation(systemID: systemID, operation: .backup, trigger: trigger, detail: "Mock backup")
    }

    let definition = BackupSystemDefinition.definition(for: systemID)
    return runScript(
      definition: definition,
      operation: .backup,
      trigger: trigger,
      scriptName: definition.backupScriptName,
      arguments: [],
      detail: "\(definition.title) backup"
    )
  }

  @discardableResult
  func runRestore(systemID: BackupSystemID, date: String, option: BackupRestoreOption) -> BackupRun.ID? {
    if isMockMode {
      return runMockOperation(
        systemID: systemID,
        operation: .restore,
        trigger: .manual,
        detail: "Mock restore: \(date), \(option.title)"
      )
    }

    let definition = BackupSystemDefinition.definition(for: systemID)
    var arguments = [date]
    if let optionArgument = option.argument {
      arguments.append(optionArgument)
    }
    arguments.append("--yes")

    return runScript(
      definition: definition,
      operation: .restore,
      trigger: .manual,
      scriptName: definition.restoreScriptName,
      arguments: arguments,
      detail: "\(definition.title) restore: \(date), \(option.title)"
    )
  }

  func stopRun(systemID: BackupSystemID) {
    guard let runID = activeRuns[systemID] else {
      return
    }

    stoppedRunIDs.insert(runID)
    append("\n[\(Self.timestampFormatter.string(from: Date()))] Stop requested\n", to: runID)

    if isMockMode {
      finish(
        runID: runID,
        status: .stopped,
        exitCode: nil,
        finalMessage: "\n[\(Self.timestampFormatter.string(from: Date()))] Stopped\n"
      )
      return
    }

    if let process = activeProcesses[runID], process.isRunning {
      process.terminate()
    }
  }

  func openBackupDirectory(for systemID: BackupSystemID) {
    let url = BackupSystemDefinition.definition(for: systemID).backupDirectoryURL
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
  }

  func availableRestoreDates(for systemID: BackupSystemID) -> [String] {
    if isMockMode {
      return ["2026-05-25", "2026-05-24", "2026-05-23"]
    }

    let definition = BackupSystemDefinition.definition(for: systemID)
    var dates = Set<String>()

    for component in definition.components {
      let componentURL = definition.backupDirectoryURL.appendingPathComponent(component.relativePath, isDirectory: true)

      switch component.kind {
      case .directory:
        for name in directorySnapshotNames(in: componentURL) {
          dates.insert(name)
        }
      case .database(let prefix, let suffix):
        for name in databaseSnapshotNames(in: componentURL, prefix: prefix, suffix: suffix) {
          dates.insert(name)
        }
      }
    }

    return dates.sorted(by: >)
  }

  func logText(for runID: BackupRun.ID?, systemID: BackupSystemID) -> String {
    if let runID, let run = runs.first(where: { $0.id == runID }) {
      return run.log.isEmpty ? "\(run.detail)\n\(run.status.title)" : run.log
    }

    guard let status = statuses[systemID] else {
      return ""
    }

    let chunks = [
      status.backupLogTail,
      status.stdoutLogTail,
      status.stderrLogTail
    ].filter { !$0.isEmpty }

    return chunks.joined(separator: "\n\n")
  }

  func logText(forBackupDate date: String, systemID: BackupSystemID) -> String {
    if let run = runs.first(where: {
      $0.systemID == systemID &&
        $0.operation == .backup &&
        Self.dayFormatter.string(from: $0.startedAt) == date
    }) {
      return run.log
    }

    guard let status = statuses[systemID] else {
      return "No logs found for \(date)."
    }

    let extractedLog = extractBackupLog(for: date, from: status.backupLogTail)
    if !extractedLog.isEmpty {
      return extractedLog
    }

    return "Backup snapshot \(date)\nNo dedicated log entry was found in the retained log tail."
  }

  private func evaluateAutomaticBackups() {
    refreshStatuses()

    let now = Date()
    let today = Self.dayFormatter.string(from: now)
    let currentTime = Calendar.current.dateComponents([.hour, .minute], from: now)

    for definition in BackupSystemDefinition.all {
      let schedule = schedule(for: definition.id)

      guard schedule.isEnabled else {
        continue
      }

      guard activeRuns[definition.id] == nil else {
        continue
      }

      guard currentTime.hour == schedule.hour, currentTime.minute == schedule.minute else {
        continue
      }

      let attemptKey = "backupAgent.lastAutomaticAttempt.\(definition.id.rawValue)"
      guard defaults.string(forKey: attemptKey) != today else {
        continue
      }

      if statuses[definition.id]?.requiredComponentsAreCurrent == true {
        defaults.set(today, forKey: attemptKey)
        continue
      }

      defaults.set(today, forKey: attemptKey)
      runBackup(systemID: definition.id, trigger: .automatic)
    }
  }

  @discardableResult
  private func runScript(
    definition: BackupSystemDefinition,
    operation: BackupOperation,
    trigger: BackupRunTrigger,
    scriptName: String,
    arguments: [String],
    detail: String
  ) -> BackupRun.ID? {
    guard activeRuns[definition.id] == nil else {
      return activeRuns[definition.id]
    }

    let run = BackupRun(
      id: UUID(),
      systemID: definition.id,
      operation: operation,
      trigger: trigger,
      startedAt: Date(),
      finishedAt: nil,
      status: .running,
      exitCode: nil,
      detail: detail,
      log: "[\(Self.timestampFormatter.string(from: Date()))] Starting \(detail)\n"
    )

    runs.insert(run, at: 0)
    activeRuns[definition.id] = run.id
    saveRuns()

    Task {
      do {
        let result = try await BackupScriptRunner.run(
          scriptName: scriptName,
          arguments: arguments,
          onProcessStart: { [weak self] process in
            Task { @MainActor in
              guard self?.activeRuns[definition.id] == run.id else {
                return
              }

              self?.activeProcesses[run.id] = process
              if self?.stoppedRunIDs.contains(run.id) == true, process.isRunning {
                process.terminate()
              }
            }
          },
          onOutput: { [weak self] text in
            Task { @MainActor in
              self?.append(text, to: run.id)
            }
          }
        )

        let wasStopped = stoppedRunIDs.contains(run.id)

        finish(
          runID: run.id,
          status: wasStopped ? .stopped : (result.exitCode == 0 ? .success : .failed),
          exitCode: result.exitCode,
          finalMessage: wasStopped
            ? "\n[\(Self.timestampFormatter.string(from: Date()))] Stopped\n"
            : "\n[\(Self.timestampFormatter.string(from: Date()))] Finished with exit code \(result.exitCode)\n"
        )
      } catch {
        append("\n\(error.localizedDescription)\n", to: run.id)
        finish(
          runID: run.id,
          status: stoppedRunIDs.contains(run.id) ? .stopped : .failed,
          exitCode: nil,
          finalMessage: "\n[\(Self.timestampFormatter.string(from: Date()))] Failed to launch script\n"
        )
      }
    }

    return run.id
  }

  private func append(_ text: String, to runID: BackupRun.ID) {
    guard let index = runs.firstIndex(where: { $0.id == runID }) else {
      return
    }

    objectWillChange.send()
    runs[index].log.append(text)
    if runs[index].log.count > 120_000 {
      runs[index].log.removeFirst(runs[index].log.count - 120_000)
    }
  }

  private func finish(
    runID: BackupRun.ID,
    status: BackupRunStatus,
    exitCode: Int32?,
    finalMessage: String
  ) {
    guard let index = runs.firstIndex(where: { $0.id == runID }) else {
      return
    }

    objectWillChange.send()
    runs[index].status = status
    runs[index].exitCode = exitCode
    runs[index].finishedAt = Date()
    runs[index].log.append(finalMessage)
    activeRuns[runs[index].systemID] = nil
    activeProcesses[runID] = nil
    stoppedRunIDs.remove(runID)

    refreshStatuses()
    saveRuns()
  }

  private func saveRuns() {
    guard !isMockMode else {
      return
    }

    do {
      try FileManager.default.createDirectory(
        at: historyURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )

      let runsToSave = Array(runs.prefix(80))
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(runsToSave).write(to: historyURL, options: .atomic)
    } catch {
      print("Failed to save backup run history: \(error.localizedDescription)")
    }
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

  private static func detectMockMode() -> Bool {
    ProcessInfo.processInfo.arguments.contains("--mock-backups") ||
      ProcessInfo.processInfo.environment["OKBRAINCC_BACKUP_MOCK"] == "1"
  }

  private static func loadSchedules(defaults: UserDefaults) -> [BackupSystemID: BackupScheduleSettings] {
    Dictionary(uniqueKeysWithValues: BackupSystemID.allCases.map { systemID in
      (systemID, defaultSchedule(for: systemID, defaults: defaults))
    })
  }

  private static func defaultSchedule(for systemID: BackupSystemID, defaults: UserDefaults) -> BackupScheduleSettings {
    let definition = BackupSystemDefinition.definition(for: systemID)
    let isEnabled = defaults.object(forKey: scheduleEnabledKey(for: systemID)) as? Bool ?? true
    let hour = defaults.object(forKey: scheduleHourKey(for: systemID)) as? Int ?? definition.scheduleHour
    let minute = defaults.object(forKey: scheduleMinuteKey(for: systemID)) as? Int ?? definition.scheduleMinute

    return BackupScheduleSettings(
      isEnabled: isEnabled,
      hour: min(max(hour, 0), 23),
      minute: min(max(minute, 0), 59)
    )
  }

  private static func scheduleEnabledKey(for systemID: BackupSystemID) -> String {
    "backupAgent.scheduleEnabled.\(systemID.rawValue)"
  }

  private static func scheduleHourKey(for systemID: BackupSystemID) -> String {
    "backupAgent.scheduleHour.\(systemID.rawValue)"
  }

  private static func scheduleMinuteKey(for systemID: BackupSystemID) -> String {
    "backupAgent.scheduleMinute.\(systemID.rawValue)"
  }

  @discardableResult
  private func runMockOperation(
    systemID: BackupSystemID,
    operation: BackupOperation,
    trigger: BackupRunTrigger,
    detail: String
  ) -> BackupRun.ID? {
    guard activeRuns[systemID] == nil else {
      return activeRuns[systemID]
    }

    let run = BackupRun(
      id: UUID(),
      systemID: systemID,
      operation: operation,
      trigger: trigger,
      startedAt: Date(),
      finishedAt: nil,
      status: .running,
      exitCode: nil,
      detail: detail,
      log: "[\(Self.timestampFormatter.string(from: Date()))] Starting \(detail)\nMock mode: no SSH command was run.\n"
    )

    runs.insert(run, at: 0)
    activeRuns[systemID] = run.id

    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 900_000_000)
      append("[\(Self.timestampFormatter.string(from: Date()))] Mock output line\n", to: run.id)
      finish(
        runID: run.id,
        status: .success,
        exitCode: 0,
        finalMessage: "\n[\(Self.timestampFormatter.string(from: Date()))] Mock \(operation.title.lowercased()) completed\n"
      )
    }

    return run.id
  }

  private func buildStatus(for definition: BackupSystemDefinition) -> BackupSystemStatus {
    if isMockMode {
      return Self.mockStatus(for: definition)
    }

    let backupDirectoryURL = definition.backupDirectoryURL
    let backupDirectoryExists = FileManager.default.fileExists(atPath: backupDirectoryURL.path)
    let today = Self.dayFormatter.string(from: Date())

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

  private func importObservedRuns(from statuses: [BackupSystemID: BackupSystemStatus]) {
    var importedRuns: [BackupRun] = []

    for definition in BackupSystemDefinition.all {
      guard let status = statuses[definition.id], !status.backupLogTail.isEmpty else {
        continue
      }

      importedRuns.append(contentsOf: observedRuns(from: status.backupLogTail, systemID: definition.id))
    }

    let newRuns = importedRuns.filter { importedRun in
      !runs.contains { existingRun in
        existingRun.systemID == importedRun.systemID &&
          existingRun.operation == importedRun.operation &&
          abs(existingRun.startedAt.timeIntervalSince(importedRun.startedAt)) < 1
      }
    }

    guard !newRuns.isEmpty else {
      return
    }

    runs.append(contentsOf: newRuns)
    runs.sort { $0.startedAt > $1.startedAt }
    saveRuns()
  }

  private func observedRuns(from log: String, systemID: BackupSystemID) -> [BackupRun] {
    var runs: [BackupRun] = []
    var startedAt: Date?
    var lines: [String] = []

    for lineSubstring in log.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(lineSubstring)

      if line.contains("=== Backup started ===") || line.contains("=== Prodbox sandbox backup started ===") {
        startedAt = timestamp(from: line)
        lines = [line]
        continue
      }

      guard startedAt != nil else {
        continue
      }

      lines.append(line)

      if line.contains("=== Backup completed ===") || line.contains("=== Prodbox sandbox backup completed ===") {
        let runStartedAt = startedAt ?? Date()
        runs.append(
          BackupRun(
            id: UUID(),
            systemID: systemID,
            operation: .backup,
            trigger: .automatic,
            startedAt: runStartedAt,
            finishedAt: timestamp(from: line),
            status: .success,
            exitCode: 0,
            detail: "Observed backup log",
            log: lines.joined(separator: "\n")
          )
        )
        startedAt = nil
        lines = []
      }
    }

    return runs
  }

  private func buildComponentStatus(
    _ component: BackupComponentDefinition,
    backupDirectoryURL: URL,
    today: String
  ) -> BackupComponentStatus {
    let componentURL = backupDirectoryURL.appendingPathComponent(component.relativePath, isDirectory: true)
    let latestDate: String?
    let snapshotCount: Int
    let isCurrentToday: Bool

    switch component.kind {
    case .directory:
      let snapshotNames = directorySnapshotNames(in: componentURL)
      latestDate = latestSymlinkDate(in: componentURL) ?? snapshotNames.sorted().last
      snapshotCount = snapshotNames.count
      isCurrentToday = latestDate == today
    case .database(let prefix, let suffix):
      let snapshotNames = databaseSnapshotNames(in: componentURL, prefix: prefix, suffix: suffix)
      latestDate = snapshotNames.sorted().last
      snapshotCount = snapshotNames.count
      isCurrentToday = snapshotNames.contains(today)
    }

    return BackupComponentStatus(
      id: component.id,
      title: component.title,
      isRequired: component.isRequired,
      latestDate: latestDate,
      snapshotCount: snapshotCount,
      size: diskUsage(for: componentURL),
      isCurrentToday: isCurrentToday,
      path: componentURL.path
    )
  }

  private func latestSymlinkDate(in componentURL: URL) -> String? {
    let latestURL = componentURL.appendingPathComponent("latest", isDirectory: false)
    guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: latestURL.path) else {
      return nil
    }

    return URL(fileURLWithPath: destination).lastPathComponent
  }

  private func directorySnapshotNames(in componentURL: URL) -> [String] {
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

  private func databaseSnapshotNames(in componentURL: URL, prefix: String, suffix: String) -> [String] {
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

  private func diskUsage(for url: URL) -> String {
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

  private func tail(of url: URL, maxBytes: UInt64 = 60_000) -> String {
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

  private func latestCompletionDate(from log: String) -> Date? {
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

  private func extractBackupLog(for date: String, from log: String) -> String {
    var isCollecting = false
    var lines: [String] = []

    for lineSubstring in log.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(lineSubstring)

      if line.hasPrefix("[\(date)") &&
        (line.contains("=== Backup started ===") || line.contains("=== Prodbox sandbox backup started ===")) {
        isCollecting = true
        lines = [line]
        continue
      }

      guard isCollecting else {
        continue
      }

      lines.append(line)

      if line.contains("=== Backup completed ===") || line.contains("=== Prodbox sandbox backup completed ===") {
        return lines.joined(separator: "\n")
      }
    }

    return lines.joined(separator: "\n")
  }

  private func timestamp(from line: String) -> Date? {
    guard line.hasPrefix("["), line.count >= 21 else {
      return nil
    }

    let timestampStart = line.index(after: line.startIndex)
    let timestampEnd = line.index(timestampStart, offsetBy: 19, limitedBy: line.endIndex) ?? line.endIndex
    return Self.timestampFormatter.date(from: String(line[timestampStart..<timestampEnd]))
  }

  private func recentErrors(from log: String) -> [String] {
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

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static func mockRuns() -> [BackupRun] {
    [
      BackupRun(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001") ?? UUID(),
        systemID: .prodbox,
        operation: .backup,
        trigger: .manual,
        startedAt: date("2026-05-25 15:44:17"),
        finishedAt: nil,
        status: .running,
        exitCode: nil,
        detail: "Mock running backup",
        log: "[2026-05-25 15:44:17] Starting Prodbox backup\nMock mode: backup is still running so Restore is hidden for this item.\n"
      ),
      BackupRun(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000002") ?? UUID(),
        systemID: .prodbox,
        operation: .backup,
        trigger: .automatic,
        startedAt: date("2026-05-24 03:30:00"),
        finishedAt: date("2026-05-24 03:33:20"),
        status: .success,
        exitCode: 0,
        detail: "Mock completed backup",
        log: "[2026-05-24 03:30:00] === Backup started ===\n[2026-05-24 03:31:05] Database backup saved\n[2026-05-24 03:33:20] === Backup completed ===\n"
      ),
      BackupRun(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000003") ?? UUID(),
        systemID: .prodboxSandbox,
        operation: .backup,
        trigger: .automatic,
        startedAt: date("2026-05-25 03:45:00"),
        finishedAt: date("2026-05-25 03:47:12"),
        status: .success,
        exitCode: 0,
        detail: "Mock sandbox backup",
        log: "[2026-05-25 03:45:00] === Prodbox sandbox backup started ===\n[2026-05-25 03:46:10] apps backup saved\n[2026-05-25 03:47:12] === Prodbox sandbox backup completed ===\n"
      )
    ].sorted { $0.startedAt > $1.startedAt }
  }

  private static func mockStatus(for definition: BackupSystemDefinition) -> BackupSystemStatus {
    let latestDate = definition.id == .prodbox ? "2026-05-24" : "2026-05-25"
    let components = definition.components.map { component in
      BackupComponentStatus(
        id: component.id,
        title: component.title,
        isRequired: component.isRequired,
        latestDate: latestDate,
        snapshotCount: 3,
        size: component.kind == .database(prefix: "brain-", suffix: ".db") ? "128M" : "24M",
        isCurrentToday: definition.id == .prodboxSandbox,
        path: definition.backupDirectoryURL.appendingPathComponent(component.relativePath).path
      )
    }

    return BackupSystemStatus(
      systemID: definition.id,
      backupDirectoryPath: definition.backupDirectoryURL.path,
      backupDirectoryExists: true,
      requiredComponentsAreCurrent: definition.id == .prodboxSandbox,
      latestCompletionDate: definition.id == .prodbox
        ? date("2026-05-24 03:33:20")
        : date("2026-05-25 03:47:12"),
      components: components,
      recentErrors: [],
      backupLogTail: "[\(latestDate) 03:30:00] === Backup started ===\n[\(latestDate) 03:33:20] === Backup completed ===\n",
      stdoutLogTail: "Mock stdout log\n",
      stderrLogTail: ""
    )
  }

  private static func date(_ string: String) -> Date {
    timestampFormatter.date(from: string) ?? Date()
  }

  static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()
}

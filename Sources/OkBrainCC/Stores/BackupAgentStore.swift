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
  @Published private(set) var restoreDates: [BackupSystemID: [String]] = [:]
  @Published private(set) var runLogs: [BackupSystemID: [String: String]] = [:]
  @Published private(set) var runComponents: [BackupSystemID: [String: [BackupComponentStatus]]] = [:]
  @Published private(set) var loadingSystemIDs = Set<BackupSystemID>()
  @Published private(set) var schedulerAnchorLoadedSystemIDs = Set<BackupSystemID>()

  private let defaults = UserDefaults.standard
  private let isMockMode: Bool
  private var scheduler: Timer?
  private var activeProcesses: [BackupRun.ID: Process] = [:]
  private var stoppedRunIDs = Set<BackupRun.ID>()
  private var schedulerLastBackupDates: [BackupSystemID: Date] = [:]
  private var loadingSchedulerAnchorSystemIDs = Set<BackupSystemID>()

  private init() {
    isMockMode = Self.detectMockMode()
    schedules = Self.loadSchedules(defaults: defaults)
    runs = isMockMode ? Self.mockRuns() : []
    restoreDates = isMockMode ? Self.mockRestoreDates() : [:]
    if isMockMode {
      activeRuns = Dictionary(uniqueKeysWithValues: runs.compactMap { run in
        run.status == .running ? (run.systemID, run.id) : nil
      })
      for definition in BackupSystemDefinition.all {
        statuses[definition.id] = Self.mockStatus(for: definition)
        schedulerAnchorLoadedSystemIDs.insert(definition.id)
        schedulerLastBackupDates[definition.id] = statuses[definition.id]?.latestCompletionDate
      }
    }
  }

  func startScheduler() {
    guard scheduler == nil else {
      return
    }

    refreshSchedulerAnchors()

    let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.evaluateAutomaticBackups()
      }
    }
    timer.tolerance = 5
    scheduler = timer
  }

  func refreshStatuses() {
    for definition in BackupSystemDefinition.all {
      loadBackupData(systemID: definition.id, force: true)
    }
  }

  func refreshSchedulerAnchors() {
    for definition in BackupSystemDefinition.all {
      loadSchedulerAnchor(systemID: definition.id, force: true)
    }
  }

  func loadBackupData(systemID: BackupSystemID, force: Bool = false) {
    if isMockMode {
      let definition = BackupSystemDefinition.definition(for: systemID)
      statuses[systemID] = Self.mockStatus(for: definition)
      restoreDates[systemID] = Self.mockRestoreDates()[systemID] ?? []
      runLogs[systemID] = Self.mockRunLogs(for: systemID)
      runComponents[systemID] = Self.mockRunComponents(for: definition)
      schedulerAnchorLoadedSystemIDs.insert(systemID)
      schedulerLastBackupDates[systemID] = statuses[systemID]?.latestCompletionDate
      return
    }

    if loadingSystemIDs.contains(systemID), !force {
      return
    }

    loadingSystemIDs.insert(systemID)

    let definition = BackupSystemDefinition.definition(for: systemID)
    let retentionLimit = schedule(for: systemID).retentionCount

    Task.detached(priority: .utility) { [definition, systemID, retentionLimit] in
      let pageData = BackupFilesystemLoader.loadPageData(
        for: definition,
        limit: retentionLimit
      )

      await MainActor.run {
        BackupAgentStore.shared.applyLoadedPageData(pageData, systemID: systemID)
      }
    }
  }

  func loadSchedulerAnchor(systemID: BackupSystemID, force: Bool = false) {
    if isMockMode {
      schedulerAnchorLoadedSystemIDs.insert(systemID)
      schedulerLastBackupDates[systemID] = statuses[systemID]?.latestCompletionDate
      evaluateAutomaticBackup(for: BackupSystemDefinition.definition(for: systemID))
      return
    }

    if loadingSchedulerAnchorSystemIDs.contains(systemID), !force {
      return
    }

    loadingSchedulerAnchorSystemIDs.insert(systemID)

    let definition = BackupSystemDefinition.definition(for: systemID)
    Task.detached(priority: .utility) { [definition, systemID] in
      let latestCompletionDate = BackupFilesystemLoader.loadLatestCompletionDate(for: definition)

      await MainActor.run {
        BackupAgentStore.shared.applyLoadedSchedulerAnchor(
          latestCompletionDate,
          systemID: systemID
        )
      }
    }
  }

  private func applyLoadedPageData(_ pageData: BackupPageData, systemID: BackupSystemID) {
    runs = runs.filter { $0.isRunning || $0.operation == .restore }

    restoreDates[systemID] = pageData.restoreDates
    statuses[systemID] = pageData.status
    if let newestRunID = pageData.restoreDates.first {
      cacheNewestBackupDetails(systemID: systemID, runID: newestRunID, status: pageData.status)
    }
    if let latestCompletionDate = pageData.status.latestCompletionDate {
      schedulerLastBackupDates[systemID] = latestCompletionDate
    } else {
      schedulerLastBackupDates[systemID] = nil
    }
    schedulerAnchorLoadedSystemIDs.insert(systemID)
    loadingSystemIDs.remove(systemID)
    evaluateAutomaticBackup(for: BackupSystemDefinition.definition(for: systemID))
  }

  private func applyLoadedSchedulerAnchor(_ latestCompletionDate: Date?, systemID: BackupSystemID) {
    if let latestCompletionDate {
      schedulerLastBackupDates[systemID] = latestCompletionDate
    } else {
      schedulerLastBackupDates[systemID] = nil
    }
    schedulerAnchorLoadedSystemIDs.insert(systemID)
    loadingSchedulerAnchorSystemIDs.remove(systemID)
    evaluateAutomaticBackup(for: BackupSystemDefinition.definition(for: systemID))
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

  func nextBackupCountdownLabel(for systemID: BackupSystemID, now: Date = Date()) -> String {
    let schedule = schedule(for: systemID)
    guard schedule.isEnabled else {
      return "Automatic backups off"
    }

    guard statuses[systemID] != nil || schedulerAnchorLoadedSystemIDs.contains(systemID) else {
      return "Checking last backup..."
    }

    guard let nextBackupDate = schedule.nextAutomaticBackupDate(
      now: now,
      lastBackupDate: lastBackupDate(for: systemID),
      lastAttemptDate: lastAutomaticAttemptDate(for: systemID)
    ) else {
      return "Automatic backups off"
    }

    let remaining = nextBackupDate.timeIntervalSince(now)
    guard remaining > 0 else {
      return "Backup due now"
    }

    return "Next backup in \(Self.durationLabel(for: remaining))"
  }

  func updateSchedule(
    systemID: BackupSystemID,
    isEnabled: Bool? = nil,
    intervalMinutes: Int? = nil,
    retentionCount: Int? = nil
  ) {
    let current = schedule(for: systemID)
    let next = BackupScheduleSettings(
      isEnabled: isEnabled ?? current.isEnabled,
      intervalMinutes: min(max(intervalMinutes ?? current.intervalMinutes, 1), 24 * 60),
      retentionCount: min(max(retentionCount ?? current.retentionCount, 1), 365)
    )

    defaults.set(next.isEnabled, forKey: Self.scheduleEnabledKey(for: systemID))
    defaults.set(next.intervalMinutes, forKey: Self.scheduleIntervalMinutesKey(for: systemID))
    defaults.set(next.retentionCount, forKey: Self.retentionCountKey(for: systemID))
    schedules[systemID] = next
    restoreDates[systemID] = restoreDates[systemID].map { Array($0.prefix(next.retentionCount)) }
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
      environment: ["OKBRAINCC_BACKUP_RETENTION_COUNT": "\(schedule(for: systemID).retentionCount)"],
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
    restoreDates[systemID] ?? []
  }

  func loadBackupDetails(systemID: BackupSystemID, backupID: String, force: Bool = false) {
    if isMockMode {
      var logs = runLogs[systemID] ?? [:]
      logs.merge(Self.mockRunLogs(for: systemID)) { current, _ in current }
      runLogs[systemID] = logs
      runComponents[systemID] = Self.mockRunComponents(for: BackupSystemDefinition.definition(for: systemID))
      return
    }

    if !force, runLogs[systemID]?[backupID] != nil, runComponents[systemID]?[backupID] != nil {
      return
    }

    let definition = BackupSystemDefinition.definition(for: systemID)
    Task.detached(priority: .utility) { [definition, systemID, backupID] in
      let details = BackupFilesystemLoader.loadRunDetails(for: definition, runID: backupID)

      await MainActor.run {
        var logs = BackupAgentStore.shared.runLogs[systemID] ?? [:]
        logs[backupID] = details.log
        BackupAgentStore.shared.runLogs[systemID] = logs

        var components = BackupAgentStore.shared.runComponents[systemID] ?? [:]
        components[backupID] = details.components
        BackupAgentStore.shared.runComponents[systemID] = components
      }
    }
  }

  func components(forBackupDate date: String, systemID: BackupSystemID) -> [BackupComponentStatus] {
    if let components = runComponents[systemID]?[date] {
      return components
    }

    if restoreDates[systemID]?.first == date {
      return statuses[systemID]?.components ?? []
    }

    return []
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
        Self.runIDFormatter.string(from: $0.startedAt) == date
    }) {
      return run.log
    }

    if let log = runLogs[systemID]?[date] {
      return log
    }

    return "Loading logs for \(date)..."
  }

  private func cacheNewestBackupDetails(systemID: BackupSystemID, runID: String, status: BackupSystemStatus) {
    let chunks = [
      status.backupLogTail,
      status.stdoutLogTail,
      status.stderrLogTail
    ].filter { !$0.isEmpty }

    guard !chunks.isEmpty else {
      return
    }

    var logs = runLogs[systemID] ?? [:]
    logs[runID] = chunks.joined(separator: "\n\n")
    runLogs[systemID] = logs

    var components = runComponents[systemID] ?? [:]
    components[runID] = status.components
    runComponents[systemID] = components
  }

  private func evaluateAutomaticBackups() {
    let now = Date()

    for definition in BackupSystemDefinition.all {
      evaluateAutomaticBackup(for: definition, now: now)
    }
  }

  private func evaluateAutomaticBackup(for definition: BackupSystemDefinition, now: Date = Date()) {
    guard statuses[definition.id] != nil || schedulerAnchorLoadedSystemIDs.contains(definition.id) else {
      loadSchedulerAnchor(systemID: definition.id)
      return
    }

    let schedule = schedule(for: definition.id)

    guard schedule.shouldRunAutomatically(
      now: now,
      lastAttemptDate: lastAutomaticAttemptDate(for: definition.id),
      lastBackupDate: lastBackupDate(for: definition.id),
      isActive: activeRuns[definition.id] != nil
    ) else {
      return
    }

    defaults.set(now, forKey: Self.lastAutomaticAttemptDateKey(for: definition.id))
    runBackup(systemID: definition.id, trigger: .automatic)
  }

  private func lastBackupDate(for systemID: BackupSystemID) -> Date? {
    statuses[systemID]?.latestCompletionDate ?? schedulerLastBackupDates[systemID]
  }

  private func lastAutomaticAttemptDate(for systemID: BackupSystemID) -> Date? {
    defaults.object(forKey: Self.lastAutomaticAttemptDateKey(for: systemID)) as? Date
  }

  @discardableResult
  private func runScript(
    definition: BackupSystemDefinition,
    operation: BackupOperation,
    trigger: BackupRunTrigger,
    scriptName: String,
    arguments: [String],
    environment: [String: String] = [:],
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

    Task {
      do {
        let result = try await BackupScriptRunner.run(
          scriptName: scriptName,
          arguments: arguments,
          extraEnvironment: environment,
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
    let systemID = runs[index].systemID
    activeRuns[systemID] = nil
    activeProcesses[runID] = nil
    stoppedRunIDs.remove(runID)
    schedulerLastBackupDates[systemID] = runs[index].finishedAt
    schedulerAnchorLoadedSystemIDs.insert(systemID)

    loadBackupData(systemID: systemID, force: true)
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
    let isEnabled = defaults.object(forKey: scheduleEnabledKey(for: systemID)) as? Bool ?? true
    let intervalMinutes = storedIntervalMinutes(for: systemID, defaults: defaults)
    let retentionCount = defaults.object(forKey: retentionCountKey(for: systemID)) as? Int ?? 30

    return BackupScheduleSettings(
      isEnabled: isEnabled,
      intervalMinutes: min(max(intervalMinutes, 1), 24 * 60),
      retentionCount: min(max(retentionCount, 1), 365)
    )
  }

  private static func storedIntervalMinutes(for systemID: BackupSystemID, defaults: UserDefaults) -> Int {
    if let intervalMinutes = defaults.object(forKey: scheduleIntervalMinutesKey(for: systemID)) as? Int {
      return intervalMinutes
    }

    if
      let legacyHour = defaults.object(forKey: scheduleHourKey(for: systemID)) as? Int,
      let legacyMinute = defaults.object(forKey: scheduleMinuteKey(for: systemID)) as? Int
    {
      let migratedInterval = max((legacyHour * 60) + legacyMinute, 1)
      defaults.set(migratedInterval, forKey: scheduleIntervalMinutesKey(for: systemID))
      return migratedInterval
    }

    return 60
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

  private static func scheduleIntervalMinutesKey(for systemID: BackupSystemID) -> String {
    "backupAgent.scheduleIntervalMinutes.\(systemID.rawValue)"
  }

  private static func lastAutomaticAttemptDateKey(for systemID: BackupSystemID) -> String {
    "backupAgent.lastAutomaticAttemptDate.\(systemID.rawValue)"
  }

  private static func retentionCountKey(for systemID: BackupSystemID) -> String {
    "backupAgent.retentionCount.\(systemID.rawValue)"
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

  private static let runIDFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    return formatter
  }()

  private static func durationLabel(for interval: TimeInterval) -> String {
    let totalMinutes = max(Int(ceil(interval / 60)), 1)
    let days = totalMinutes / (24 * 60)
    let hours = (totalMinutes % (24 * 60)) / 60
    let minutes = totalMinutes % 60

    if days > 0 {
      return "\(days)d \(hours)h"
    }

    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }

    return "\(minutes)m"
  }

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

  private static func mockRestoreDates() -> [BackupSystemID: [String]] {
    [
      .prodbox: ["2026-05-25-1544", "2026-05-24-0330", "2026-05-23-0330"],
      .prodboxSandbox: ["2026-05-25-0345", "2026-05-24-0345", "2026-05-23-0345"]
    ]
  }

  private static func mockStatus(for definition: BackupSystemDefinition) -> BackupSystemStatus {
    let latestDate = definition.id == .prodbox ? "2026-05-24-0330" : "2026-05-25-0345"
    let latestLog = definition.id == .prodbox
      ? "[2026-05-24 03:30:00] === Backup started: 2026-05-24-0330 ===\n[2026-05-24 03:33:20] === Backup completed: 2026-05-24-0330 ===\n"
      : "[2026-05-25 03:45:00] === Prodbox sandbox backup started: 2026-05-25-0345 ===\n[2026-05-25 03:47:12] === Prodbox sandbox backup completed: 2026-05-25-0345 ===\n"
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
      backupLogTail: latestLog,
      stdoutLogTail: "Mock stdout log\n",
      stderrLogTail: ""
    )
  }

  private static func mockRunLogs(for systemID: BackupSystemID) -> [String: String] {
    switch systemID {
    case .prodbox:
      [
        "2026-05-25-1544": "[2026-05-25 15:44:17] Starting Prodbox backup\nMock mode: backup is still running so Restore is hidden for this item.\n",
        "2026-05-24-0330": "[2026-05-24 03:30:00] === Backup started: 2026-05-24-0330 ===\n[2026-05-24 03:31:05] Database backup saved\n[2026-05-24 03:33:20] === Backup completed: 2026-05-24-0330 ===\n",
        "2026-05-23-0330": "[2026-05-23 03:30:00] === Backup started: 2026-05-23-0330 ===\n[2026-05-23 03:33:15] === Backup completed: 2026-05-23-0330 ===\n"
      ]
    case .prodboxSandbox:
      [
        "2026-05-25-0345": "[2026-05-25 03:45:00] === Prodbox sandbox backup started: 2026-05-25-0345 ===\n[2026-05-25 03:46:10] apps backup saved\n[2026-05-25 03:47:12] === Prodbox sandbox backup completed: 2026-05-25-0345 ===\n",
        "2026-05-24-0345": "[2026-05-24 03:45:00] === Prodbox sandbox backup started: 2026-05-24-0345 ===\n[2026-05-24 03:47:00] === Prodbox sandbox backup completed: 2026-05-24-0345 ===\n",
        "2026-05-23-0345": "[2026-05-23 03:45:00] === Prodbox sandbox backup started: 2026-05-23-0345 ===\n[2026-05-23 03:47:02] === Prodbox sandbox backup completed: 2026-05-23-0345 ===\n"
      ]
    }
  }

  private static func mockRunComponents(for definition: BackupSystemDefinition) -> [String: [BackupComponentStatus]] {
    let backupIDs = mockRestoreDates()[definition.id] ?? []
    return Dictionary(uniqueKeysWithValues: backupIDs.map { backupID in
      let components = definition.components.map { component in
        BackupComponentStatus(
          id: component.id,
          title: component.title,
          isRequired: component.isRequired,
          latestDate: backupID,
          snapshotCount: backupIDs.count,
          size: component.id == "db" ? "128M" : "24M",
          isCurrentToday: backupID.hasPrefix("2026-05-25"),
          path: definition.backupDirectoryURL
            .appendingPathComponent("runs")
            .appendingPathComponent(backupID)
            .appendingPathComponent(component.relativePath)
            .path
        )
      }

      return (backupID, components)
    })
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

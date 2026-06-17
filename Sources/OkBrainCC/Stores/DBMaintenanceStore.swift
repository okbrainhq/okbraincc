import AppKit
import Combine
import Foundation

@MainActor
final class DBMaintenanceStore: ObservableObject {
  static let shared = DBMaintenanceStore()

  @Published private(set) var runs: [DBMaintenanceRun] = []
  @Published private(set) var activeRunID: UUID?
  @Published private(set) var schedule: DBMaintenanceScheduleSettings
  @Published private(set) var remoteHost: String
  @Published private(set) var isLoading = false

  /// Tracks the next action to run after a successful dry-run (composite flow).
  private var pendingCompositeAction: DBMaintenanceRunType?

  private let defaults = AppEnvironment.userDefaults
  private let isMockMode: Bool
  private var scheduler: Timer?
  private var activeProcess: Process?
  private var stoppedRunIDs = Set<UUID>()
  private var lastAutomaticRunDate: Date?

  private init() {
    isMockMode = Self.detectMockMode()
    schedule = Self.loadSchedule(defaults: defaults)
    remoteHost = defaults.string(forKey: Self.remoteHostKey) ?? Self.defaultRemoteHost
    lastAutomaticRunDate = defaults.object(forKey: Self.lastAutomaticAttemptDateKey) as? Date

    if isMockMode {
      runs = Self.mockRuns()
    } else {
      runs = Self.loadPersistedRuns()
    }
  }

  // MARK: - Scheduler

  func startScheduler() {
    guard scheduler == nil else { return }

    let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.evaluateAutomaticRun()
      }
    }
    timer.tolerance = 10
    scheduler = timer
  }

  private func evaluateAutomaticRun() {
    guard schedule.isEnabled, activeRunID == nil else { return }

    let now = Date()
    guard schedule.shouldRunAutomatically(
      now: now,
      lastAttemptDate: lastAutomaticRunDate,
      lastRunDate: lastSuccessfulRunDate,
      isActive: activeRunID != nil
    ) else {
      return
    }

    lastAutomaticRunDate = now
    defaults.set(now, forKey: Self.lastAutomaticAttemptDateKey)
    runAutomaticMaintenance()
  }

  private var lastSuccessfulRunDate: Date? {
    runs.first { $0.status == .success }?.finishedAt
  }

  // MARK: - Actions

  @discardableResult
  func runMaintenance(type: DBMaintenanceRunType, trigger: DBMaintenanceTrigger = .manual) -> UUID? {
    guard activeRunID == nil else { return activeRunID }

    let run = DBMaintenanceRun(
      id: UUID(),
      runType: type,
      trigger: trigger,
      startedAt: Date(),
      finishedAt: nil,
      status: .running,
      exitCode: nil,
      detail: "\(type.title) maintenance",
      log: "[\(Self.timestampFormatter.string(from: Date()))] Starting \(type.title) maintenance\n"
    )

    runs.insert(run, at: 0)
    activeRunID = run.id
    persistRun(run)

    if trigger == .automatic {
      lastAutomaticRunDate = Date()
      defaults.set(Date(), forKey: Self.lastAutomaticAttemptDateKey)
    }

    if isMockMode {
      runMockExecution(runID: run.id, type: type)
    } else {
      runScript(runID: run.id, type: type)
    }

    return run.id
  }

  /// Runs the full automatic flow: dry-run first, then apply if dry-run succeeds.
  func runAutomaticMaintenance() {
    guard activeRunID == nil else { return }
    pendingCompositeAction = .apply
    runMaintenance(type: .dryRun, trigger: .automatic)
  }

  /// Runs dry-run first, then apply if successful.
  func runApplyWithDryRun() -> UUID? {
    guard activeRunID == nil else { return activeRunID }
    pendingCompositeAction = .apply
    return runMaintenance(type: .dryRun)
  }

  /// Runs dry-run first, then vacuum if successful.
  func runVacuumWithDryRun() -> UUID? {
    guard activeRunID == nil else { return activeRunID }
    pendingCompositeAction = .vacuum
    return runMaintenance(type: .dryRun)
  }

  func stopRun() {
    guard let runID = activeRunID else { return }

    stoppedRunIDs.insert(runID)
    append(
      "[\(Self.timestampFormatter.string(from: Date()))] Stop requested\n",
      to: runID
    )

    if isMockMode {
      finish(runID: runID, status: .stopped, exitCode: nil,
             finalMessage: "[\(Self.timestampFormatter.string(from: Date()))] Stopped\n")
      return
    }

    if let process = activeProcess, process.isRunning {
      process.terminate()
    }
  }

  func updateSchedule(
    isEnabled: Bool? = nil,
    intervalMinutes: Int? = nil,
    retentionDays: Int? = nil
  ) {
    let current = schedule
    let next = DBMaintenanceScheduleSettings(
      isEnabled: isEnabled ?? current.isEnabled,
      intervalMinutes: min(max(intervalMinutes ?? current.intervalMinutes, 60), 24 * 60),
      retentionDays: min(max(retentionDays ?? current.retentionDays, 1), 365)
    )

    defaults.set(next.isEnabled, forKey: Self.scheduleEnabledKey)
    defaults.set(next.intervalMinutes, forKey: Self.scheduleIntervalMinutesKey)
    defaults.set(next.retentionDays, forKey: Self.retentionDaysKey)
    schedule = next
  }

  func updateRemoteHost(_ host: String) {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    defaults.set(trimmed, forKey: Self.remoteHostKey)
    remoteHost = trimmed
  }

  func refreshRuns() {
    runs = isMockMode ? Self.mockRuns() : Self.loadPersistedRuns()
  }

  func logText(for runID: UUID?) -> String {
    guard let runID, let run = runs.first(where: { $0.id == runID }) else {
      return ""
    }

    return run.log.isEmpty ? "\(run.detail)\n\(run.status.title)" : run.log
  }

  var nextRunCountdownLabel: String {
    guard schedule.isEnabled else { return "Automatic maintenance off" }

    guard let nextDate = schedule.nextAutomaticRunDate(
      now: Date(),
      lastRunDate: lastSuccessfulRunDate,
      lastAttemptDate: lastAutomaticRunDate
    ) else {
      return "Automatic maintenance off"
    }

    let remaining = nextDate.timeIntervalSince(Date())
    guard remaining > 0 else { return "Maintenance due now" }

    return "Next run in \(Self.durationLabel(for: remaining))"
  }

  // MARK: - Script Execution

  private func runScript(runID: UUID, type: DBMaintenanceRunType) {
    let environment: [String: String] = [
      "OKBRAINCC_DB_MAINTENANCE_REMOTE_HOST": remoteHost,
      "OKBRAINCC_DB_MAINTENANCE_RETENTION_DAYS": "\(schedule.retentionDays)"
    ]

    Task {
      do {
        let result = try await BackupScriptRunner.run(
          scriptName: type.scriptName,
          arguments: [],
          extraEnvironment: environment,
          onProcessStart: { [weak self] process in
            Task { @MainActor in
              guard self?.activeRunID == runID else { return }
              self?.activeProcess = process
              if self?.stoppedRunIDs.contains(runID) == true, process.isRunning {
                process.terminate()
              }
            }
          },
          onOutput: { [weak self] text in
            Task { @MainActor in
              self?.append(text, to: runID)
            }
          }
        )

        let wasStopped = stoppedRunIDs.contains(runID)
        let finalStatus: DBMaintenanceRunStatus = wasStopped
          ? .stopped
          : (result.exitCode == 0 ? .success : .failed)

        finish(
          runID: runID,
          status: finalStatus,
          exitCode: result.exitCode,
          finalMessage: wasStopped
            ? "\n[\(Self.timestampFormatter.string(from: Date()))] Stopped\n"
            : "\n[\(Self.timestampFormatter.string(from: Date()))] Finished with exit code \(result.exitCode)\n"
        )

        // Composite flow: if dry-run succeeded and there's a pending action, proceed
        if !wasStopped, result.exitCode == 0, type == .dryRun, let nextAction = pendingCompositeAction {
          pendingCompositeAction = nil
          runMaintenance(type: nextAction, trigger: runs.first { $0.id == runID }?.trigger ?? .manual)
        } else if type == .dryRun {
          // Clear pending if dry-run failed or was stopped
          pendingCompositeAction = nil
        }
      } catch {
        pendingCompositeAction = nil
        append("\n\(error.localizedDescription)\n", to: runID)
        finish(
          runID: runID,
          status: stoppedRunIDs.contains(runID) ? .stopped : .failed,
          exitCode: nil,
          finalMessage: "\n[\(Self.timestampFormatter.string(from: Date()))] Failed to launch script\n"
        )
      }
    }
  }

  // MARK: - Run Management

  private func append(_ text: String, to runID: UUID) {
    guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }

    objectWillChange.send()
    runs[index].log.append(text)
    if runs[index].log.count > 120_000 {
      runs[index].log.removeFirst(runs[index].log.count - 120_000)
    }
    persistRun(runs[index])
  }

  private func finish(
    runID: UUID,
    status: DBMaintenanceRunStatus,
    exitCode: Int32?,
    finalMessage: String
  ) {
    guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }

    objectWillChange.send()
    runs[index].status = status
    runs[index].exitCode = exitCode
    runs[index].finishedAt = Date()
    runs[index].log.append(finalMessage)
    activeRunID = nil
    activeProcess = nil
    stoppedRunIDs.remove(runID)
    persistRun(runs[index])

    pruneOldRuns()
  }

  // MARK: - Persistence

  private static var runsDirectoryURL: URL {
    let dir = "okbraincc-db-maintenance" + AppEnvironment.current.stateDirectorySuffix
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(dir, isDirectory: true)
      .appendingPathComponent("runs", isDirectory: true)
  }

  private func persistRun(_ run: DBMaintenanceRun) {
    let directoryURL = Self.runsDirectoryURL
    let jsonURL = directoryURL.appendingPathComponent("\(run.id.uuidString).json")
    let logURL = directoryURL.appendingPathComponent("\(run.id.uuidString).log")

    do {
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(run)
      try data.write(to: jsonURL, options: [.atomic])
      try run.log.write(to: logURL, atomically: true, encoding: .utf8)
    } catch {
      // Best-effort persistence
    }
  }

  private static func loadPersistedRuns() -> [DBMaintenanceRun] {
    let directoryURL = Self.runsDirectoryURL
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    let decoder = JSONDecoder()
    return entries
      .filter { $0.pathExtension == "json" }
      .compactMap { url -> DBMaintenanceRun? in
        guard let data = try? Data(contentsOf: url) else { return nil }
        var run = try? decoder.decode(DBMaintenanceRun.self, from: data)
        if run?.status == .running {
          run?.status = .stopped
          let existingFinishedAt = run?.finishedAt
          let startedAt = run?.startedAt
          run?.finishedAt = existingFinishedAt ?? startedAt
          run?.log.append("\nRun was still marked as running when the app loaded.\n")
        }
        return run
      }
      .sorted { $0.startedAt > $1.startedAt }
  }

  private func pruneOldRuns() {
    let retentionDays = schedule.retentionDays
    let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
    let directoryURL = Self.runsDirectoryURL

    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }

    for entry in entries {
      guard let modDate = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
            modDate < cutoff else { continue }
      try? FileManager.default.removeItem(at: entry)
    }

    runs.removeAll { run in
      guard let finishedAt = run.finishedAt else { return false }
      return finishedAt < cutoff
    }
  }

  // MARK: - Mock Mode

  private static func detectMockMode() -> Bool {
    ProcessInfo.processInfo.arguments.contains("--mock-backups") ||
      ProcessInfo.processInfo.environment["OKBRAINCC_BACKUP_MOCK"] == "1"
  }

  private func runMockExecution(runID: UUID, type: DBMaintenanceRunType) {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 800_000_000)
      append("[\(Self.timestampFormatter.string(from: Date()))] Mock: connecting to \(remoteHost)\n", to: runID)
      try? await Task.sleep(nanoseconds: 600_000_000)
      append("[\(Self.timestampFormatter.string(from: Date()))] Mock: running cleanup script (\(type.title))\n", to: runID)
      try? await Task.sleep(nanoseconds: 500_000_000)
      append("[\(Self.timestampFormatter.string(from: Date()))] Mock: rows to delete: 1234\n", to: runID)
      append("[\(Self.timestampFormatter.string(from: Date()))] Mock: estimated reclaim: 45MB\n", to: runID)

      finish(
        runID: runID,
        status: .success,
        exitCode: 0,
        finalMessage: "\n[\(Self.timestampFormatter.string(from: Date()))] Mock \(type.title.lowercased()) completed\n"
      )

      // Composite flow in mock mode
      if type == .dryRun, let nextAction = pendingCompositeAction {
        pendingCompositeAction = nil
        runMaintenance(type: nextAction, trigger: runs.first { $0.id == runID }?.trigger ?? .manual)
      }
    }
  }

  // MARK: - Static Helpers

  private static func mockRuns() -> [DBMaintenanceRun] {
    [
      DBMaintenanceRun(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000001") ?? UUID(),
        runType: .apply,
        trigger: .automatic,
        startedAt: date("2026-06-15 03:30:00"),
        finishedAt: date("2026-06-15 03:32:15"),
        status: .success,
        exitCode: 0,
        detail: "Apply maintenance",
        log: "[2026-06-15 03:30:00] Starting Apply maintenance\n[2026-06-15 03:30:01] Connecting to prodbox.local\n[2026-06-15 03:30:05] Running cleanup with --apply\n[2026-06-15 03:32:10] Deleted 8523 rows, reclaimed 32MB\n[2026-06-15 03:32:15] Finished with exit code 0\n"
      ),
      DBMaintenanceRun(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000002") ?? UUID(),
        runType: .dryRun,
        trigger: .automatic,
        startedAt: date("2026-06-15 03:29:00"),
        finishedAt: date("2026-06-15 03:29:45"),
        status: .success,
        exitCode: 0,
        detail: "Dry Run maintenance",
        log: "[2026-06-15 03:29:00] Starting Dry Run maintenance\n[2026-06-15 03:29:01] Connecting to prodbox.local\n[2026-06-15 03:29:05] Running cleanup (dry-run)\n[2026-06-15 03:29:40] Rows to delete: 8523, estimated reclaim: 32MB\n[2026-06-15 03:29:45] Finished with exit code 0\n"
      ),
      DBMaintenanceRun(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000003") ?? UUID(),
        runType: .vacuum,
        trigger: .manual,
        startedAt: date("2026-06-10 14:00:00"),
        finishedAt: date("2026-06-10 14:05:30"),
        status: .success,
        exitCode: 0,
        detail: "Vacuum maintenance",
        log: "[2026-06-10 14:00:00] Starting Vacuum maintenance\n[2026-06-10 14:00:01] Stopping brain service\n[2026-06-10 14:00:05] Running cleanup with --apply --vacuum\n[2026-06-10 14:04:50] Vacuum completed, DB compacted\n[2026-06-10 14:04:55] Starting brain service\n[2026-06-10 14:05:30] Finished with exit code 0\n"
      )
    ].sorted { $0.startedAt > $1.startedAt }
  }

  private static func loadSchedule(defaults: UserDefaults) -> DBMaintenanceScheduleSettings {
    let isEnabled = defaults.object(forKey: scheduleEnabledKey) as? Bool ?? true
    let intervalMinutes = defaults.object(forKey: scheduleIntervalMinutesKey) as? Int ?? 1440
    let retentionDays = defaults.object(forKey: retentionDaysKey) as? Int ?? 10

    return DBMaintenanceScheduleSettings(
      isEnabled: isEnabled,
      intervalMinutes: min(max(intervalMinutes, 60), 24 * 60),
      retentionDays: min(max(retentionDays, 1), 365)
    )
  }

  // MARK: - UserDefaults Keys

  private static let scheduleEnabledKey = "dbMaintenance.scheduleEnabled"
  private static let scheduleIntervalMinutesKey = "dbMaintenance.scheduleIntervalMinutes"
  private static let retentionDaysKey = "dbMaintenance.retentionDays"
  private static let remoteHostKey = "dbMaintenance.remoteHost"
  private static let lastAutomaticAttemptDateKey = "dbMaintenance.lastAutomaticAttemptDate"

  private static let defaultRemoteHost = "arunoda@prodbox.local"

  // MARK: - Formatters

  static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
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

  private static func date(_ string: String) -> Date {
    timestampFormatter.date(from: string) ?? Date()
  }
}

import AppKit
import Combine
import Foundation

typealias DBMaintenanceExecutor = (
  DBMaintenanceRunType, [String: String], @escaping (Process) -> Void,
  @escaping @Sendable (String) -> Void
) async throws -> BackupScriptResult

@MainActor
final class DBMaintenanceStore: ObservableObject {
  static let shared = DBMaintenanceStore(
    defaults: AppEnvironment.userDefaults,
    runsDirectoryURL: defaultRunsDirectoryURL,
    isMockMode: ProcessInfo.processInfo.arguments.contains("--mock-backups") ||
      ProcessInfo.processInfo.environment["OKBRAINCC_BACKUP_MOCK"] == "1"
  )

  @Published private(set) var runs: [DBMaintenanceRun] = []
  @Published private(set) var activeRunID: UUID?
  @Published private(set) var schedule: DBMaintenanceScheduleSettings
  @Published private(set) var remoteHost: String
  @Published private(set) var safety: DBMaintenanceSafetySettings
  @Published private(set) var persistenceError: String?

  private struct Composite {
    let target: DBMaintenanceRunType
    let trigger: DBMaintenanceTrigger
    let configuration: DBMaintenanceConfiguration
  }
  private var pendingComposite: Composite?
  private let defaults: UserDefaults
  let runsDirectoryURL: URL
  private let isMockMode: Bool
  private let execute: DBMaintenanceExecutor
  private var scheduler: Timer?
  private var activeProcess: Process?
  private var stoppedRunIDs = Set<UUID>()
  private var loggingFailedRunIDs = Set<UUID>()
  private var lastAutomaticRunDate: Date?
  private var cursors: [String: String]

  // Dependency injection is intentionally explicit: tests never initialize the shared store,
  // read real preferences, contact SSH, start the scheduler, or prune real saved runs.
  init(defaults: UserDefaults, runsDirectoryURL: URL, isMockMode: Bool = false,
       execute: DBMaintenanceExecutor? = nil) {
    self.defaults = defaults
    self.runsDirectoryURL = runsDirectoryURL
    self.isMockMode = isMockMode
    self.execute = execute ?? { type, environment, onStart, onOutput in
      try await BackupScriptRunner.run(
        scriptName: type.scriptName, arguments: [], extraEnvironment: environment,
        maximumOutputLength: nil, onProcessStart: onStart, onOutput: onOutput
      )
    }
    schedule = Self.loadSchedule(defaults: defaults)
    remoteHost = defaults.string(forKey: Self.remoteHostKey) ?? "arunoda@prodbox.local"
    safety = Self.loadSafety(defaults: defaults)
    cursors = defaults.dictionary(forKey: Self.cursorsKey) as? [String: String] ?? [:]
    lastAutomaticRunDate = defaults.object(forKey: Self.lastAutomaticAttemptDateKey) as? Date
    runs = Self.loadPersistedRuns(at: runsDirectoryURL)
  }

  // MARK: - Existing scheduler (same enabled/interval/retention keys and defaults)

  func startScheduler() {
    guard scheduler == nil else { return }
    let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.evaluateAutomaticRun() }
    }
    timer.tolerance = 10
    scheduler = timer
  }

  private func evaluateAutomaticRun() {
    guard schedule.shouldRunAutomatically(
      now: Date(), lastAttemptDate: lastAutomaticRunDate,
      lastRunDate: lastSuccessfulRunDate, isActive: activeRunID != nil
    ) else { return }
    runAutomaticMaintenance()
  }

  private var lastSuccessfulRunDate: Date? {
    runs.first { [.success, .warning, .incomplete].contains($0.status) }?.finishedAt
  }

  // MARK: - Actions

  @discardableResult
  func runMaintenance(type: DBMaintenanceRunType, trigger: DBMaintenanceTrigger = .manual) -> UUID? {
    guard activeRunID == nil else { return activeRunID }
    guard type != .vacuum || trigger == .manual else { return nil } // No automatic Vacuum, including API callers.
    if type != .dryRun { return startComposite(target: type, trigger: trigger) }
    return startRun(type: type, trigger: trigger, configuration: configuration(previewOnly: true))
  }

  func runAutomaticMaintenance() {
    _ = startComposite(target: .apply, trigger: .automatic)
  }

  func runApplyWithDryRun() -> UUID? {
    startComposite(target: .apply, trigger: .manual)
  }

  func runVacuumWithDryRun() -> UUID? {
    startComposite(target: .vacuum, trigger: .manual)
  }

  private func configuration(previewOnly: Bool = false) -> DBMaintenanceConfiguration {
    var settings = safety
    if previewOnly { settings.deleteImages = false }
    var result = DBMaintenanceConfiguration(remoteHost: remoteHost, retentionDays: schedule.retentionDays, safety: settings)
    result.imagePolicyVersion = 2
    result.scheduleIntervalMinutes = schedule.intervalMinutes
    result.scheduleEnabled = schedule.isEnabled
    result.imageAfterID = cursors[result.sweepKey] ?? ""
    return result
  }

  private func startComposite(target: DBMaintenanceRunType, trigger: DBMaintenanceTrigger) -> UUID? {
    guard activeRunID == nil else { return activeRunID }
    let frozen = configuration(previewOnly: target == .vacuum)
    pendingComposite = Composite(target: target, trigger: trigger, configuration: frozen)
    return startRun(type: .dryRun, trigger: trigger, configuration: frozen, validationType: target)
  }

  private func startRun(type: DBMaintenanceRunType, trigger: DBMaintenanceTrigger,
                        configuration: DBMaintenanceConfiguration, validationType: DBMaintenanceRunType? = nil) -> UUID {
    let mode = type == .vacuum ? "manual offline Vacuum; image preview only" :
      "online; Brain not stopped (no service checks/stop/start)"
    let header = "Starting \(type.title). Frozen host=\(configuration.remoteHost), cutoff age=\(configuration.retentionDays) days.\n" +
      "Schedule: \(configuration.scheduleEnabled == true ? "enabled" : "off"), every \(configuration.scheduleIntervalMinutes ?? schedule.intervalMinutes) minutes; trigger=\(trigger.rawValue). Mode: \(mode).\n" +
      "Scope: tool history only; conversations/messages/jobs/repository files retained. Images: \(configuration.safety.deleteImages ? "automatic online cleanup (Dry Run still read-only)" : "preview only").\n" +
      "Image eligibility: upload AND owning chat/recent activity older than \(configuration.retentionDays) days, inactive jobs; backend enforces user/unknown/shared/retained-reference protections.\n"
    let run = DBMaintenanceRun(id: UUID(), runType: type, trigger: trigger, startedAt: Date(), finishedAt: nil,
                               status: .running, exitCode: nil, detail: "\(type.title) maintenance", log: header,
                               configuration: configuration)
    runs.insert(run, at: 0)
    activeRunID = run.id
    if trigger == .automatic {
      lastAutomaticRunDate = Date()
      defaults.set(lastAutomaticRunDate, forKey: Self.lastAutomaticAttemptDateKey)
    }
    guard persistRun(run) else {
      pendingComposite = nil
      _ = finish(runID: run.id, status: .failed, exitCode: nil, message: "Cannot persist audit log; no script launched.\n")
      return run.id
    }
    if let error = configuration.validationError(for: validationType ?? type) {
      pendingComposite = nil
      _ = finish(runID: run.id, status: .failed, exitCode: 2, message: "Blocked: \(error)\n")
      return run.id
    }

    Task {
      do {
        let result: BackupScriptResult
        if isMockMode {
          result = BackupScriptResult(exitCode: 0, output: "MOCK ONLY: no remote execution.\nCC_RESULT {\"outcome\":\"warning\",\"history\":\"\(type == .dryRun ? "dry_run_zero_deletions" : "apply_succeeded_actual_counts_unavailable")\",\"images\":null,\"restorationFailed\":false,\"partial\":false,\"error\":null}\n")
        } else {
          result = try await execute(type, configuration.environment, { [weak self] process in
            Task { @MainActor in
              guard self?.activeRunID == run.id else { return }
              self?.activeProcess = process
              if self?.stoppedRunIDs.contains(run.id) == true || self?.loggingFailedRunIDs.contains(run.id) == true,
                 process.isRunning { process.terminate() }
            }
          }, { [weak self] text in
            Task { @MainActor in
              guard self?.activeRunID == run.id else { return }
              self?.append(text, to: run.id)
            }
          })
        }
        complete(runID: run.id, type: type, configuration: configuration, header: header, result: result)
      } catch {
        pendingComposite = nil
        _ = finish(runID: run.id, status: .failed, exitCode: nil,
                   message: "Script launch/transport failed: \(error.localizedDescription). Remote outcome/restoration may require verification.\n")
      }
    }
    return run.id
  }

  private func complete(runID: UUID, type: DBMaintenanceRunType, configuration: DBMaintenanceConfiguration,
                        header: String, result: BackupScriptResult) {
    guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
    let stopped = stoppedRunIDs.contains(runID)
    let loggingFailed = loggingFailedRunIDs.contains(runID)
    let report = DBMaintenanceReport.parse(result.output)
    // Authoritative, untruncated capture reconciles asynchronous live-output callbacks.
    runs[index].log = header + result.output
    runs[index].report = report
    var status = report?.status(exitCode: result.exitCode) ?? .failed
    if loggingFailed { status = report?.partial == true ? .partial : .failed }
    else if stopped, report?.restorationFailed != true { status = .stopped }
    let next = pendingComposite
    pendingComposite = nil
    let message = "\nFinished exit=\(result.exitCode); \(status.title).\n" +
      (report == nil ? "Missing terminal report: outcome and service restoration UNCONFIRMED; no success claimed.\n" : "") +
      (loggingFailed ? "Audit persistence failed during execution; cancellation requested.\n" : "")
    let persisted = finish(runID: runID, status: status, exitCode: result.exitCode, message: message)
    // A Dry Run in a pair must NEVER advance the Apply cursor, nor consume its frozen snapshot.
    if type == .dryRun, let next, !stopped, !loggingFailed, persisted,
       result.exitCode == 0, report?.permitsApply == true {
      _ = startRun(type: next.target, trigger: next.trigger, configuration: next.configuration)
    } else if next == nil, persisted, let images = report?.images, images.cursorCanAdvance,
              images.mode == configuration.imageMode,
              images.mode != "online-apply" || result.exitCode == 0 {
      // Nonzero online exits NEVER advance progress, even if a report claims otherwise. Preview progress stays separate.
      cursors[configuration.sweepKey] = images.nextAfterID ?? ""
      defaults.set(cursors, forKey: Self.cursorsKey)
    }
  }

  func stopRun() {
    guard let runID = activeRunID else { return }
    stoppedRunIDs.insert(runID)
    pendingComposite = nil
    let offline = runs.first { $0.id == runID }?.runType == .vacuum
    append(offline ? "Stop requested; waiting for remote child termination and Vacuum service restoration. Do not force-quit CC.\n" :
      "Stop requested; waiting for remote child termination; online, Brain not stopped. Do not force-quit CC.\n", to: runID)
    if let process = activeProcess, process.isRunning { process.terminate() }
  }

  func stopForAppTermination() async {
    scheduler?.invalidate()
    scheduler = nil
    guard activeRunID != nil else { return }
    stopRun()
    // The transport has a bounded cancellation wait and reports unconfirmed restoration on timeout.
    // Do not kill SSH/cleanup groups from the GUI or bypass remote restoration.
    while activeRunID != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
  }

  func updateSchedule(isEnabled: Bool? = nil, intervalMinutes: Int? = nil, retentionDays: Int? = nil) {
    let next = DBMaintenanceScheduleSettings(isEnabled: isEnabled ?? schedule.isEnabled,
      intervalMinutes: min(max(intervalMinutes ?? schedule.intervalMinutes, 60), 1440),
      retentionDays: min(max(retentionDays ?? schedule.retentionDays, 1), 365))
    defaults.set(next.isEnabled, forKey: Self.scheduleEnabledKey)
    defaults.set(next.intervalMinutes, forKey: Self.scheduleIntervalMinutesKey)
    defaults.set(next.retentionDays, forKey: Self.retentionDaysKey)
    schedule = next
  }

  /// Explicit post-migration image disabling is preserved; blank roots use the source default.
  func updateConfiguration(host: String, safety: DBMaintenanceSafetySettings) -> String? {
    let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    var safety = safety
    if safety.uploadsDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      safety.uploadsDirectory = DBMaintenanceSafetySettings.defaultUploadsDirectory
    }
    let config = DBMaintenanceConfiguration(remoteHost: host, retentionDays: schedule.retentionDays, safety: safety)
    if let error = config.validationError(for: .apply) { return error }
    guard let data = try? JSONEncoder().encode(safety) else { return "Could not encode maintenance settings." }
    defaults.set(data, forKey: Self.safetyKey)
    defaults.set(host, forKey: Self.remoteHostKey)
    self.safety = safety
    remoteHost = host
    return nil
  }

  func refreshRuns() {
    guard activeRunID == nil else { return }
    runs = Self.loadPersistedRuns(at: runsDirectoryURL)
  }

  func logText(for runID: UUID?) -> String {
    runs.first { $0.id == runID }?.log ?? ""
  }

  var imageProgressLabel: String {
    let cursor = configuration().imageAfterID
    return cursor.isEmpty ? "Next image sweep starts at the beginning (max 300 rows/run)." :
      "Image sweep incomplete; next run resumes after \(cursor) (max 300 rows/run)."
  }

  var nextRunCountdownLabel: String {
    guard let next = schedule.nextAutomaticRunDate(now: Date(), lastRunDate: lastSuccessfulRunDate,
                                                  lastAttemptDate: lastAutomaticRunDate) else { return "Automatic maintenance off" }
    let remaining = next.timeIntervalSinceNow
    guard remaining > 0 else { return "Maintenance due now" }
    let minutes = max(Int(ceil(remaining / 60)), 1)
    return "Next run in \(minutes / 60)h \(minutes % 60)m"
  }

  // MARK: - Durable full logs (existing run JSON remains readable)

  private func append(_ text: String, to runID: UUID) {
    guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
    runs[index].log.append(text)
    if !persistRun(runs[index]) {
      loggingFailedRunIDs.insert(runID)
      pendingComposite = nil
      if let process = activeProcess, process.isRunning { process.terminate() }
    }
  }

  @discardableResult
  private func finish(runID: UUID, status: DBMaintenanceRunStatus, exitCode: Int32?, message: String) -> Bool {
    guard let index = runs.firstIndex(where: { $0.id == runID }) else { return false }
    runs[index].status = status
    runs[index].exitCode = exitCode
    runs[index].finishedAt = Date()
    runs[index].log.append(message)
    activeRunID = nil
    activeProcess = nil
    stoppedRunIDs.remove(runID)
    loggingFailedRunIDs.remove(runID)
    let persisted = persistRun(runs[index])
    if !persisted { runs[index].status = .failed }
    if persisted { pruneOldRuns() }
    return persisted
  }

  private func persistRun(_ run: DBMaintenanceRun) -> Bool {
    do {
      try FileManager.default.createDirectory(at: runsDirectoryURL, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(run).write(to: runsDirectoryURL.appendingPathComponent("\(run.id).json"), options: .atomic)
      try run.log.write(to: runsDirectoryURL.appendingPathComponent("\(run.id).log"), atomically: true, encoding: .utf8)
      return true
    } catch {
      persistenceError = "Audit log write failed: \(error.localizedDescription). Maintenance cannot be reported as successful."
      return false
    }
  }

  private static func loadPersistedRuns(at directory: URL) -> [DBMaintenanceRun] {
    let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return entries.filter { $0.pathExtension == "json" }.compactMap { url -> DBMaintenanceRun? in
      guard let data = try? Data(contentsOf: url), var run = try? JSONDecoder().decode(DBMaintenanceRun.self, from: data) else { return nil }
      if run.status == .running {
        run.status = .stopped
        run.finishedAt = run.finishedAt ?? run.startedAt
        run.log.append("\nCC restarted during this run. Remote outcome/service restoration UNCONFIRMED; inspect before retrying.\n")
      }
      return run
    }.sorted { $0.startedAt > $1.startedAt }
  }

  private func pruneOldRuns() {
    let cutoff = Date().addingTimeInterval(-Double(schedule.retentionDays) * 86400)
    for run in runs where run.finishedAt.map({ $0 < cutoff }) == true {
      for ext in ["json", "log"] {
        try? FileManager.default.removeItem(at: runsDirectoryURL.appendingPathComponent("\(run.id).\(ext)"))
      }
    }
    runs.removeAll { $0.finishedAt.map { $0 < cutoff } == true }
  }

  private static var defaultRunsDirectoryURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("okbraincc-db-maintenance" + AppEnvironment.current.stateDirectorySuffix)
      .appendingPathComponent("runs", isDirectory: true)
  }

  private static func loadSchedule(defaults: UserDefaults) -> DBMaintenanceScheduleSettings {
    DBMaintenanceScheduleSettings(
      isEnabled: defaults.object(forKey: scheduleEnabledKey) as? Bool ?? true,
      intervalMinutes: min(max(defaults.object(forKey: scheduleIntervalMinutesKey) as? Int ?? 1440, 60), 1440),
      retentionDays: min(max(defaults.object(forKey: retentionDaysKey) as? Int ?? 10, 1), 365))
  }

  private static func loadSafety(defaults: UserDefaults) -> DBMaintenanceSafetySettings {
    // A separate versioned settings key is the migration marker. Never migrate audit configurations.
    if let data = defaults.data(forKey: safetyKey),
       var saved = try? JSONDecoder().decode(DBMaintenanceSafetySettings.self, from: data) {
      if saved.uploadsDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        saved.uploadsDirectory = DBMaintenanceSafetySettings.defaultUploadsDirectory
        if let normalized = try? JSONEncoder().encode(saved) { defaults.set(normalized, forKey: safetyKey) }
      }
      return saved // Includes explicit v2 deleteImages=false; do not re-enable on every launch.
    }
    var migrated = defaults.data(forKey: legacySafetyKey)
      .flatMap { try? JSONDecoder().decode(DBMaintenanceSafetySettings.self, from: $0) } ?? DBMaintenanceSafetySettings()
    migrated.deleteImages = true // User-authorized replacement of the v1 preview-only policy.
    if migrated.uploadsDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      migrated.uploadsDirectory = DBMaintenanceSafetySettings.defaultUploadsDirectory
    }
    if let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: safetyKey) }
    return migrated
  }

  private static let scheduleEnabledKey = "dbMaintenance.scheduleEnabled"
  private static let scheduleIntervalMinutesKey = "dbMaintenance.scheduleIntervalMinutes"
  private static let retentionDaysKey = "dbMaintenance.retentionDays"
  private static let remoteHostKey = "dbMaintenance.remoteHost"
  private static let lastAutomaticAttemptDateKey = "dbMaintenance.lastAutomaticAttemptDate"
  private static let legacySafetyKey = "dbMaintenance.safety.v1"
  private static let safetyKey = "dbMaintenance.safety.v2"
  private static let cursorsKey = "dbMaintenance.imageSweepCursors.v2"
}

import Foundation

@MainActor private final class FixtureExecutor {
  var calls: [(DBMaintenanceRunType, [String: String])] = []
  var hold = false
  var release: CheckedContinuation<Void, Never>?
  var exit: Int32 = 0
  var outcome = "success"
  var missingReport = false
  var largeOutput = false
  var liveOutput = ""

  func run(_ type: DBMaintenanceRunType, _ env: [String: String], output: @Sendable (String) -> Void) async -> BackupScriptResult {
    calls.append((type, env))
    if !liveOutput.isEmpty { output(liveOutput) }
    if hold { await withCheckedContinuation { release = $0 } }
    let text = liveOutput + (largeOutput ? String(repeating: "metadata only\n", count: 12_000) : "fixture\n") + (missingReport ? "" : """
    CC_RESULT {"outcome":"\(outcome)","history":"\(type == .dryRun ? "dry_run_zero_deletions" : "scoped_history_applied")","images":null,"restorationFailed":false,"partial":\(exit != 0),"error":null,"historyCounts":{"tool_call_logs":{"candidates":12,"deleted":\(type == .dryRun ? 0 : 12)}},"databaseCheck":"ok","compaction":"optimize-passive-checkpoint"}
    """)
    output(text)
    return BackupScriptResult(exitCode: exit, output: text)
  }
}

@MainActor private final class Fixture {
  let suite = "test.okbraincc.maintenance." + UUID().uuidString
  let defaults: UserDefaults
  let directory: URL
  init() throws {
    defaults = UserDefaults(suiteName: suite)!
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  func clean() throws {
    defaults.removePersistentDomain(forName: suite)
    try FileManager.default.removeItem(at: directory)
  }
  func store(_ executor: FixtureExecutor, runs: URL? = nil) -> DBMaintenanceStore {
    DBMaintenanceStore(defaults: defaults, runsDirectoryURL: runs ?? directory.appendingPathComponent("runs"),
      execute: { type, env, _, output in await executor.run(type, env, output: output) })
  }
  func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw Failure.test("Timed out")
  }
}

private enum Failure: Error { case test(String) }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String = "Assertion failed", line: UInt = #line) throws {
  if !condition() { throw Failure.test("Line \(line): \(message)") }
}

@main @MainActor private enum VerifyMaintenance {
  static func main() async {
    let tests: [(String, (Fixture) async throws -> Void)] = [
      ("daily default and single online execution", { f in
        let e = FixtureExecutor(), s = f.store(FixtureExecutor())
        try expect(s.schedule.isEnabled && s.schedule.retentionDays == 10 && s.schedule.intervalMinutes == 1440)
        let store = f.store(e)
        store.runAutomaticMaintenance()
        try await f.wait { store.activeRunID == nil }
        try expect(e.calls.map(\.0) == [.apply])
        try expect(e.calls[0].1["OKBRAINCC_DB_MAINTENANCE_DELETE_IMAGES"] == "1")
        try expect(e.calls[0].1["OKBRAINCC_DB_MAINTENANCE_RETENTION_DAYS"] == "10")
        try expect(e.calls[0].1["OKBRAINCC_DB_MAINTENANCE_DOWNTIME_ACKNOWLEDGED"] == "0")
        try expect(store.runs.first?.configuration?.imagePolicyVersion == 3)
        try expect(store.runs.first?.report?.historyCounts?["tool_call_logs"]?.deleted == 12)
      }),
      ("disabled schedule retained; manual cleanup available", { f in
        f.defaults.set(false, forKey: "dbMaintenance.scheduleEnabled")
        f.defaults.set(240, forKey: "dbMaintenance.scheduleIntervalMinutes")
        f.defaults.set(23, forKey: "dbMaintenance.retentionDays")
        let e = FixtureExecutor(), s = f.store(FixtureExecutor())
        try expect(!s.schedule.isEnabled && s.schedule.retentionDays == 23 && s.schedule.intervalMinutes == 1440)
        let store = f.store(e)
        store.runAutomaticMaintenance(); store.evaluateAutomaticRun()
        try expect(e.calls.isEmpty && store.runs.isEmpty)
        _ = store.runCleanup()
        try await f.wait { store.activeRunID == nil }
        try expect(e.calls.map(\.0) == [.apply])
      }),
      ("settings frozen for a running cleanup", { f in
        let e = FixtureExecutor(); e.hold = true
        let s = f.store(e)
        s.runAutomaticMaintenance()
        try await f.wait { e.release != nil }
        s.updateSchedule(retentionDays: 30)
        var settings = s.safety; settings.database = "/different/fixture.db"
        try expect(s.updateConfiguration(host: "new-fixture", safety: settings) == nil)
        e.release?.resume()
        try await f.wait { s.activeRunID == nil }
        try expect(e.calls[0].1["OKBRAINCC_DB_MAINTENANCE_RETENTION_DAYS"] == "10")
        try expect(s.runs[0].configuration?.retentionDays == 10)
        try expect(s.schedule.retentionDays == 30)
      }),
      ("hostname and policy settings validate and survive reload", { f in
        let e = FixtureExecutor(), s = f.store(e)
        var safety = s.safety
        safety.database = "/fixture/database.db"; safety.uploadsDirectory = "/fixture/uploads"
        let original = s.remoteHost
        for invalid in ["", "-oProxyCommand=unsafe", "host; echo unsafe", "user@host:22"] {
          try expect(s.updateConfiguration(host: invalid, safety: safety) != nil)
          try expect(s.remoteHost == original && s.safety.database != safety.database)
        }
        try expect(s.updateConfiguration(host: "  user@fixture.local ", safety: safety) == nil)
        s.updateSchedule(isEnabled: false, retentionDays: 18)
        let reload = f.store(e)
        try expect(reload.remoteHost == "user@fixture.local")
        try expect(reload.safety.database == safety.database && reload.safety.uploadsDirectory == safety.uploadsDirectory)
        try expect(!reload.schedule.isEnabled && reload.schedule.retentionDays == 18)
        _ = reload.runCleanup(); try await f.wait { reload.activeRunID == nil }
        try expect(e.calls[0].1["OKBRAINCC_DB_MAINTENANCE_REMOTE_HOST"] == "user@fixture.local")
        try expect(e.calls[0].1["OKBRAINCC_DB_MAINTENANCE_RETENTION_DAYS"] == "18")
      }),
      ("live logs and Stop work for cleanup and Vacuum without overlap", { f in
        let e = FixtureExecutor(); e.hold = true; e.liveOutput = "CC_PROGRESS fixture batch committed\n"
        let s = f.store(e)
        for type in [DBMaintenanceRunType.apply, .vacuum] {
          let id = type == .vacuum ? s.runVacuum(confirmed: true) : s.runCleanup()
          try await f.wait { e.release != nil && s.runs.first?.log.contains(e.liveOutput) == true }
          try expect(s.runs.first?.report == nil && s.activeRunID == id && !s.isStopping)
          try expect(s.runCleanup() == id && s.runVacuum(confirmed: true) == nil)
          s.stopRun(); s.stopRun()
          try expect(s.isStopping && s.activeRunID == id)
          try expect(s.runs.first!.log.components(separatedBy: "Stop requested;").count == 2)
          e.release?.resume(); e.release = nil
          try await f.wait { s.activeRunID == nil }
          try expect(!s.isStopping && s.runs.first?.status == .stopped)
        }
        try expect(e.calls.map(\.0) == [.apply, .vacuum])
      }),
      ("old image toggle and cursors cannot disable the unified policy", { f in
        var settings = DBMaintenanceSafetySettings()
        settings.deleteImages = false; settings.uploadsDirectory = "/fixture/uploads"
        f.defaults.set(try JSONEncoder().encode(settings), forKey: "dbMaintenance.safety.v2")
        f.defaults.set(["old-scope": "300"], forKey: "dbMaintenance.imageSweepCursors.v2")
        let e = FixtureExecutor(), s = f.store(FixtureExecutor())
        try expect(s.safety.uploadsDirectory == "/fixture/uploads")
        let store = f.store(e); store.runAutomaticMaintenance()
        try await f.wait { store.activeRunID == nil }
        try expect(e.calls[0].1["OKBRAINCC_DB_MAINTENANCE_AFTER_ID"] == "")
        try expect(e.calls[0].1["OKBRAINCC_DB_MAINTENANCE_DELETE_IMAGES"] == "1")
      }),
      ("manual Vacuum has one per-run confirmation", { f in
        let e = FixtureExecutor(), s = f.store(FixtureExecutor())
        try expect(s.runVacuum(confirmed: false) == nil)
        try expect(s.runMaintenance(type: .vacuum, trigger: .automatic) == nil)
        let store = f.store(e)
        _ = store.runVacuum(confirmed: true)
        try await f.wait { store.activeRunID == nil }
        try expect(e.calls.map(\.0) == [.vacuum])
        try expect(e.calls[0].1["OKBRAINCC_DB_MAINTENANCE_DELETE_IMAGES"] == "0")
        try expect(e.calls[0].1["OKBRAINCC_DB_MAINTENANCE_DOWNTIME_ACKNOWLEDGED"] == "1")
        try expect(!store.safety.downtimeAcknowledged && !store.safety.writersAcknowledged)
      }),
      ("daily scheduling and one-hour failed-run retry", { _ in
        let settings = DBMaintenanceScheduleSettings(isEnabled: true, intervalMinutes: 1440, retentionDays: 10)
        let now = Date()
        try expect(settings.nextAutomaticRunDate(now: now, lastRunDate: now, lastAttemptDate: nil) == now.addingTimeInterval(86400))
        try expect(settings.nextAutomaticRunDate(now: now, lastRunDate: nil, lastAttemptDate: now) == now.addingTimeInterval(3600))
        try expect(!settings.shouldRunAutomatically(now: now, lastAttemptDate: nil, lastRunDate: nil, isActive: true))
        try expect(settings.shouldRunAutomatically(now: now, lastAttemptDate: nil, lastRunDate: nil, isActive: false))
      }),
      ("preview and Vacuum do not postpone daily cleanup", { f in
        let e = FixtureExecutor(), s = f.store(FixtureExecutor())
        _ = s.runMaintenance(type: .dryRun)
        try await f.wait { s.activeRunID == nil }
        _ = s.runVacuum(confirmed: true)
        try await f.wait { s.activeRunID == nil }
        let store = f.store(e)
        store.evaluateAutomaticRun()
        try await f.wait { store.activeRunID == nil }
        try expect(e.calls.map(\.0) == [.apply])
      }),
      ("failed work retried after restart without waiting a day", { f in
        let e = FixtureExecutor(); e.exit = 2; e.outcome = "partial"
        let s = f.store(e); s.runAutomaticMaintenance()
        try await f.wait { s.activeRunID == nil }
        let next = FixtureExecutor(), store = f.store(FixtureExecutor())
        store.evaluateAutomaticRun(now: Date().addingTimeInterval(3500))
        try expect(store.activeRunID == nil)
        let reload = f.store(next)
        reload.evaluateAutomaticRun(now: Date().addingTimeInterval(3700))
        try await f.wait { reload.activeRunID == nil }
        try expect(next.calls.map(\.0) == [.apply])
      }),
      ("successful daily cleanup not duplicated", { f in
        let e = FixtureExecutor(), s = f.store(FixtureExecutor())
        s.runAutomaticMaintenance()
        try await f.wait { s.activeRunID == nil }
        let reload = f.store(e); reload.evaluateAutomaticRun()
        try expect(e.calls.isEmpty && reload.activeRunID == nil)
      }),
      ("launch catches up immediately and stops cleanly", { f in
        let e = FixtureExecutor(), s = f.store(FixtureExecutor())
        s.updateSchedule(isEnabled: false)
        s.startScheduler(); try expect(s.activeRunID == nil)
        await s.stopForAppTermination()
        let store = f.store(e); store.updateSchedule(isEnabled: true)
        store.startScheduler()
        try await f.wait { store.activeRunID == nil }
        await store.stopForAppTermination()
        try expect(e.calls.map(\.0) == [.apply])
      }),
      ("stop and missing reports never claim success", { f in
        let e = FixtureExecutor(); e.hold = true
        let s = f.store(e); s.runAutomaticMaintenance()
        try await f.wait { e.release != nil }
        s.stopRun(); e.release?.resume()
        try await f.wait { s.activeRunID == nil }
        try expect(s.runs.first?.status == .stopped)
        e.hold = false; e.missingReport = true
        _ = s.runCleanup(); try await f.wait { s.activeRunID == nil }
        try expect(s.runs.first?.status == .failed)
        try expect(s.runs.first?.log.contains("UNCONFIRMED") == true)
      }),
      ("complete audit persists without output truncation", { f in
        let e = FixtureExecutor(); e.largeOutput = true
        let s = f.store(e); _ = s.runCleanup()
        try await f.wait { s.activeRunID == nil }
        try expect(s.runs[0].log.count > 120_000)
        try expect(f.store(FixtureExecutor()).runs.first == s.runs.first)
      }),
      ("audit failure blocks execution", { f in
        let file = f.directory.appendingPathComponent("file")
        try Data("fixture".utf8).write(to: file)
        let e = FixtureExecutor(), s = f.store(FixtureExecutor())
        try expect(s.persistenceError == nil)
        let store = f.store(e, runs: file); _ = store.runCleanup()
        try expect(store.persistenceError != nil && e.calls.isEmpty)
      }),
      ("legacy audit remains truthful", { _ in
        let data = Data("""
        {"id":"20000000-0000-0000-0000-000000000001","runType":"apply","trigger":"automatic","startedAt":100,"finishedAt":200,"status":"success","exitCode":0,"detail":"old","log":"legacy"}
        """.utf8)
        let run = try JSONDecoder().decode(DBMaintenanceRun.self, from: data)
        try expect(run.configuration == nil && run.report == nil && run.log == "legacy")
      })
    ]
    var failures = 0
    for (name, test) in tests {
      do {
        let f = try Fixture()
        do { try await test(f); print("PASS \(name)") }
        catch { failures += 1; print("FAIL \(name): \(error)") }
        try f.clean()
      } catch { failures += 1; print("FAIL fixture: \(error)") }
    }
    print("DB maintenance Store tests: \(tests.count - failures) passed, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
  }
}

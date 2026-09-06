import Foundation

@MainActor
private final class FixtureExecutor {
  var calls: [(DBMaintenanceRunType, [String: String])] = []
  var holdDryRun = false
  var release: CheckedContinuation<Void, Never>?
  var dryRunExit: Int32 = 0
  var applyExit: Int32 = 0
  var missingReport = false
  var restorationFailed = false
  var largeOutput = false
  var nextCursor: String? = nil

  func run(_ type: DBMaintenanceRunType, _ environment: [String: String], output: @Sendable (String) -> Void) async -> BackupScriptResult {
    calls.append((type, environment))
    if holdDryRun && type == .dryRun {
      await withCheckedContinuation { release = $0 }
    }
    let exit = type == .dryRun ? dryRunExit : applyExit
    let report: [String: Any] = [
      "outcome": exit == 0 ? (nextCursor == nil ? "success" : "incomplete") : "partial",
      "history": type == .dryRun ? "dry_run_zero_deletions" : "apply_succeeded_actual_counts_unavailable",
      "partial": exit != 0 || restorationFailed,
      "restorationFailed": restorationFailed && type != .dryRun,
      "error": exit == 0 ? NSNull() : "fixture_per_file_error",
      "images": [
        "mode": type != .dryRun && environment["OKBRAINCC_DB_MAINTENANCE_DELETE_IMAGES"] == "1" ? "apply" : "preview",
        "batches": 3, "examined": 300, "candidates": 12, "candidateBytes": 120,
        "deleted": type == .dryRun ? 0 : 10, "deletedBytes": type == .dryRun ? 0 : 100,
        "missingFinalized": type == .dryRun ? 0 : 1, "errors": exit == 0 ? 0 : 2,
        "reasons": ["protected_user": 200, "retained_db_reference": 80],
        "nextAfterID": nextCursor as Any? ?? NSNull(), "sweepComplete": nextCursor == nil,
        "cursorCanAdvance": true, "unconfirmedBatch": false
      ]
    ]
    let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    var text = "FIRST METADATA LINE\n"
    if largeOutput { text += String(repeating: "fixture metadata only\n", count: 8000) }
    if !missingReport { text += "CC_RESULT " + String(decoding: data, as: UTF8.self) + "\n" }
    output(text)
    return BackupScriptResult(exitCode: exit, output: text)
  }
}

@MainActor
final class DBMaintenanceTests {
  private var suiteName = ""
  private var preferences: UserDefaults!
  private var directory: URL!

  func setUp() throws {
    suiteName = "test.okbraincc.maintenance." + UUID().uuidString
    preferences = UserDefaults(suiteName: suiteName)!
    preferences.removePersistentDomain(forName: suiteName)
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("okbraincc-fixture-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func tearDown() throws {
    preferences.removePersistentDomain(forName: suiteName)
    try FileManager.default.removeItem(at: directory)
  }

  private func store(_ fixture: FixtureExecutor, runs: URL? = nil) -> DBMaintenanceStore {
    DBMaintenanceStore(defaults: preferences, runsDirectoryURL: runs ?? directory.appendingPathComponent("runs"),
      execute: { type, env, _, output in await fixture.run(type, env, output: output) })
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    fail("Fixture condition timed out")
  }

  private func enableImages(_ store: DBMaintenanceStore) {
    var safety = DBMaintenanceSafetySettings()
    safety.uploadsDirectory = "/fixture/uploads"
    safety.deleteImages = true
    safety.downtimeAcknowledged = true
    safety.writersAcknowledged = true
    safety.externalReferencesAcknowledged = true
    expectNil(store.updateConfiguration(host: "fixture", safety: safety))
  }

  func testLegacySettingsAndRunDecoding() throws {
    preferences.set(false, forKey: "dbMaintenance.scheduleEnabled")
    preferences.set(240, forKey: "dbMaintenance.scheduleIntervalMinutes")
    preferences.set(23, forKey: "dbMaintenance.retentionDays")
    preferences.set("legacy-fixture", forKey: "dbMaintenance.remoteHost")
    let store = store(FixtureExecutor())
    expectFalse(store.schedule.isEnabled)
    expectEqual(store.schedule.intervalMinutes, 240)
    expectEqual(store.schedule.retentionDays, 23)
    expectEqual(store.remoteHost, "legacy-fixture")
    expectFalse(store.safety.deleteImages)
    expectFalse(store.safety.externalReferencesAcknowledged)
    expectTrue(store.safety.uploadsDirectory.isEmpty)
    let oldRun = """
    {"id":"20000000-0000-0000-0000-000000000001","runType":"apply","trigger":"automatic",
    "startedAt":100,"finishedAt":200,"status":"success","exitCode":0,"detail":"Apply maintenance","log":"legacy log"}
    """
    let decoded = try JSONDecoder().decode(DBMaintenanceRun.self, from: Data(oldRun.utf8))
    expectEqual(decoded.log, "legacy log")
    expectNil(decoded.configuration)
    expectNil(decoded.report)
    let empty = try JSONDecoder().decode(DBMaintenanceSafetySettings.self, from: Data("{}".utf8))
    expectFalse(empty.deleteImages)
    expectFalse(empty.writersAcknowledged)
  }

  func testExistingAutomaticScheduleStillDryRunThenApplyPreviewOnly() async throws {
    let fixture = FixtureExecutor()
    let store = store(fixture)
    expectTrue(store.schedule.isEnabled)
    expectEqual(store.schedule.intervalMinutes, 1440)
    expectEqual(store.schedule.retentionDays, 10)
    store.runAutomaticMaintenance()
    try await waitUntil { store.activeRunID == nil }
    expectEqual(fixture.calls.map(\.0), [.dryRun, .apply])
    expectTrue(store.runs.allSatisfy { $0.trigger == .automatic })
    for (_, env) in fixture.calls {
      expectEqual(env["OKBRAINCC_DB_MAINTENANCE_DELETE_IMAGES"], "0")
      expectEqual(env["OKBRAINCC_DB_MAINTENANCE_EXTERNAL_REFERENCES_ACKNOWLEDGED"], "0")
    }
    expectNil(store.runMaintenance(type: .vacuum, trigger: .automatic))
    expectEqual(fixture.calls.count, 2)
  }

  func testFrozenSettingsUsedByBothPhasesEvenAfterEdits() async throws {
    let fixture = FixtureExecutor()
    fixture.holdDryRun = true
    let store = store(fixture)
    enableImages(store)
    store.runAutomaticMaintenance()
    try await waitUntil { fixture.release != nil }
    let frozen = fixture.calls[0].1
    store.updateSchedule(intervalMinutes: 60, retentionDays: 90)
    var changed = DBMaintenanceSafetySettings()
    changed.database = "/different-fixture/brain.db"
    changed.uploadsDirectory = "/different-fixture/uploads"
    expectNil(store.updateConfiguration(host: "different-fixture", safety: changed))
    fixture.release?.resume()
    try await waitUntil { store.activeRunID == nil }
    expectEqual(fixture.calls.map(\.0), [.dryRun, .apply])
    expectEqual(fixture.calls[1].1, frozen)
    expectEqual(store.runs[0].configuration, store.runs[1].configuration)
    expectEqual(store.runs[0].configuration?.retentionDays, 10)
    expectEqual(store.safety, changed)
  }

  func testPartialDryRunOrMissingReportNeverStartsApply() async throws {
    let fixture = FixtureExecutor()
    fixture.dryRunExit = 1
    let store = store(fixture)
    store.runAutomaticMaintenance()
    try await waitUntil { store.activeRunID == nil }
    expectEqual(fixture.calls.map(\.0), [.dryRun])
    expectEqual(store.runs.first?.status, .partial)
    fixture.dryRunExit = 0
    fixture.missingReport = true
    store.runAutomaticMaintenance()
    try await waitUntil { store.activeRunID == nil }
    expectEqual(fixture.calls.map(\.0), [.dryRun, .dryRun])
    expectEqual(store.runs.first?.status, .failed)
    expectTrue(store.runs.first?.log.contains("UNCONFIRMED") == true)
  }

  func testFullAuditLogAndStructuredReportPersistAcrossStoreReload() async throws {
    let fixture = FixtureExecutor()
    fixture.largeOutput = true
    let store = store(fixture)
    store.runMaintenance(type: .dryRun)
    try await waitUntil { store.activeRunID == nil }
    let run = try unwrap(store.runs.first)
    expectGreater(run.log.count, 120_000)
    expectTrue(run.log.contains("FIRST METADATA LINE"))
    expectEqual(run.report?.images?.deleted, 0)
    expectEqual(run.report?.images?.reasons["protected_user"], 200)
    let log = try String(contentsOf: store.runsDirectoryURL.appendingPathComponent("\(run.id).log"), encoding: .utf8)
    expectEqual(log, run.log)
    let reloaded = self.store(FixtureExecutor())
    expectEqual(reloaded.runs.first, run)
  }

  func testCursorResumesAfterReloadAndDryRunNeverConsumesApplyCursor() async throws {
    let fixture = FixtureExecutor()
    fixture.nextCursor = "300"
    let store = store(fixture)
    enableImages(store)
    // Standalone Dry Run advances only preview progress.
    store.runMaintenance(type: .dryRun)
    try await waitUntil { store.activeRunID == nil }
    expectTrue(store.safety.deleteImages)
    store.runAutomaticMaintenance()
    try await waitUntil { store.activeRunID == nil }
    expectEqual(fixture.calls[1].1["OKBRAINCC_DB_MAINTENANCE_AFTER_ID"], "")
    expectEqual(fixture.calls[2].1["OKBRAINCC_DB_MAINTENANCE_AFTER_ID"], "")
    expectEqual(store.runs.first?.status, .incomplete)
    let secondFixture = FixtureExecutor()
    let reloaded = self.store(secondFixture)
    reloaded.runAutomaticMaintenance()
    try await waitUntil { reloaded.activeRunID == nil }
    expectEqual(secondFixture.calls[0].1["OKBRAINCC_DB_MAINTENANCE_AFTER_ID"], "300")
    expectEqual(secondFixture.calls[1].1["OKBRAINCC_DB_MAINTENANCE_AFTER_ID"], "300")
    // Complete traversal resets this scope to the start, so protected/error rows get retried.
    reloaded.runAutomaticMaintenance()
    try await waitUntil { reloaded.activeRunID == nil }
    expectEqual(secondFixture.calls[2].1["OKBRAINCC_DB_MAINTENANCE_AFTER_ID"], "")
  }

  func testStoppedCompositeDryRunDoesNotAdvanceImageDeletionCursor() async throws {
    let fixture = FixtureExecutor()
    fixture.holdDryRun = true
    fixture.nextCursor = "300"
    let store = store(fixture)
    enableImages(store)
    store.runAutomaticMaintenance()
    try await waitUntil { fixture.release != nil }
    store.stopRun()
    fixture.release?.resume()
    try await waitUntil { store.activeRunID == nil }
    expectEqual(fixture.calls.count, 1)
    expectEqual(store.runs.first?.status, .stopped)
    let next = FixtureExecutor()
    let reloaded = self.store(next)
    reloaded.runAutomaticMaintenance()
    try await waitUntil { reloaded.activeRunID == nil }
    expectEqual(next.calls[0].1["OKBRAINCC_DB_MAINTENANCE_AFTER_ID"], "")
  }

  func testApplyPartialProgressPersistsButIsNotSuccess() async throws {
    let fixture = FixtureExecutor()
    fixture.nextCursor = "300"
    fixture.applyExit = 1
    let store = store(fixture)
    enableImages(store)
    store.runAutomaticMaintenance()
    try await waitUntil { store.activeRunID == nil }
    expectEqual(store.runs.first?.status, .partial)
    expectEqual(store.runs.first?.report?.images?.errors, 2)
    let next = FixtureExecutor()
    let reloaded = self.store(next)
    reloaded.runAutomaticMaintenance()
    try await waitUntil { reloaded.activeRunID == nil }
    expectEqual(next.calls[0].1["OKBRAINCC_DB_MAINTENANCE_AFTER_ID"], "300")
  }

  func testSafetyAndRestorationFailureClassification() throws {
    var safety = DBMaintenanceSafetySettings()
    safety.deleteImages = true
    var config = DBMaintenanceConfiguration(remoteHost: "fixture", retentionDays: 10, safety: safety)
    expectNotNil(config.validationError(for: .apply))
    safety.deleteImages = false
    config = DBMaintenanceConfiguration(remoteHost: "-oProxyCommand=oops", retentionDays: 10, safety: safety)
    expectNotNil(config.validationError(for: .dryRun))
    config = DBMaintenanceConfiguration(remoteHost: "fixture", retentionDays: 10, safety: safety)
    expectNotNil(config.validationError(for: .vacuum))
    let failure = DBMaintenanceReport(outcome: "success", history: "apply_succeeded_actual_counts_unavailable",
      images: nil, restorationFailed: true, partial: true, error: "restart_failed")
    expectEqual(failure.status(exitCode: 0), .partial)
    expectEqual(failure.status(exitCode: 4), .partial)
    expectFalse(failure.permitsApply)
  }

  func testAuditWriteFailureBlocksExecutionAndIsVisible() async throws {
    let fixture = FixtureExecutor()
    let file = directory.appendingPathComponent("not-a-directory")
    try Data("fixture".utf8).write(to: file)
    let store = store(fixture, runs: file)
    store.runAutomaticMaintenance()
    try await waitUntil { store.activeRunID == nil }
    expectTrue(fixture.calls.isEmpty)
    expectNotNil(store.persistenceError)
    expectEqual(store.runs.first?.status, .failed)
  }

  func testUnfinishedOldRunReloadIsUnconfirmedNotSuccessful() throws {
    let store = store(FixtureExecutor())
    try FileManager.default.createDirectory(at: store.runsDirectoryURL, withIntermediateDirectories: true)
    let run = DBMaintenanceRun(id: UUID(), runType: .apply, trigger: .automatic, startedAt: Date(),
      finishedAt: nil, status: .running, exitCode: nil, detail: "fixture", log: "fixture log")
    try JSONEncoder().encode(run).write(to: store.runsDirectoryURL.appendingPathComponent("\(run.id).json"))
    store.refreshRuns()
    expectEqual(store.runs.first?.status, .stopped)
    expectTrue(store.runs.first?.log.contains("UNCONFIRMED") == true)
  }

  func testScheduleTimingRemainsIntervalBasedAndActiveRunBlocks() {
    let schedule = DBMaintenanceScheduleSettings(isEnabled: true, intervalMinutes: 1440, retentionDays: 10)
    let anchor = Date(timeIntervalSinceReferenceDate: 10_000)
    expectEqual(schedule.nextAutomaticRunDate(now: anchor, lastRunDate: anchor, lastAttemptDate: nil), anchor.addingTimeInterval(86400))
    expectFalse(schedule.shouldRunAutomatically(now: anchor.addingTimeInterval(86400), lastAttemptDate: nil, lastRunDate: anchor, isActive: true))
    expectTrue(schedule.shouldRunAutomatically(now: anchor.addingTimeInterval(86400), lastAttemptDate: nil, lastRunDate: anchor, isActive: false))
  }
}


// Standalone verification, matching scripts/verify_scheduler.swift. No XCTest/Xcode dependency,
// app entry point, real preferences, scheduler start, SSH, or live process access.
@MainActor private var assertionFailures = 0

@MainActor private func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
  assertionFailures += 1
  print("FAIL \(file):\(line): \(message)")
}
@MainActor private func expectTrue(_ value: Bool, file: StaticString = #fileID, line: UInt = #line) {
  if !value { fail("Expected true", file: file, line: line) }
}
@MainActor private func expectFalse(_ value: Bool, file: StaticString = #fileID, line: UInt = #line) {
  expectTrue(!value, file: file, line: line)
}
@MainActor private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) {
  if a != b { fail("Values differ: \(a) != \(b)", file: file, line: line) }
}
@MainActor private func expectNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) {
  if value != nil { fail("Expected nil", file: file, line: line) }
}
@MainActor private func expectNotNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) {
  if value == nil { fail("Expected non-nil", file: file, line: line) }
}
@MainActor private func expectGreater(_ a: Int, _ b: Int, file: StaticString = #fileID, line: UInt = #line) {
  if a <= b { fail("Expected \(a) > \(b)", file: file, line: line) }
}
private enum FixtureError: Error { case missingValue }
@MainActor private func unwrap<T>(_ value: T?) throws -> T {
  guard let value else { throw FixtureError.missingValue }
  return value
}

@main @MainActor private enum VerifyMaintenance {
  static func main() async {
    let tests: [(String, (DBMaintenanceTests) async throws -> Void)] = [
      ("legacy decoding", { try $0.testLegacySettingsAndRunDecoding() }),
      ("existing automatic preview schedule", { try await $0.testExistingAutomaticScheduleStillDryRunThenApplyPreviewOnly() }),
      ("frozen phase settings", { try await $0.testFrozenSettingsUsedByBothPhasesEvenAfterEdits() }),
      ("failed/missing Dry Run blocks Apply", { try await $0.testPartialDryRunOrMissingReportNeverStartsApply() }),
      ("full durable audit log", { try await $0.testFullAuditLogAndStructuredReportPersistAcrossStoreReload() }),
      ("resumable separate cursors", { try await $0.testCursorResumesAfterReloadAndDryRunNeverConsumesApplyCursor() }),
      ("cancelled preview never advances Apply cursor", { try await $0.testStoppedCompositeDryRunDoesNotAdvanceImageDeletionCursor() }),
      ("partial Apply progress", { try await $0.testApplyPartialProgressPersistsButIsNotSuccess() }),
      ("safety/restoration status", { try $0.testSafetyAndRestorationFailureClassification() }),
      ("audit write failure", { try await $0.testAuditWriteFailureBlocksExecutionAndIsVisible() }),
      ("interrupted run reload", { try $0.testUnfinishedOldRunReloadIsUnconfirmedNotSuccessful() }),
      ("unchanged schedule timing", { $0.testScheduleTimingRemainsIntervalBasedAndActiveRunBlocks() })
    ]
    var failedTests = 0
    for (name, test) in tests {
      let before = assertionFailures
      let fixture = DBMaintenanceTests()
      do {
        try fixture.setUp()
        try await test(fixture)
      } catch { fail("\(name): \(error)") }
      do { try fixture.tearDown() } catch { fail("Fixture cleanup: \(error)") }
      if assertionFailures != before { failedTests += 1 }
      print("\(assertionFailures == before ? "PASS" : "FAIL") \(name)")
    }
    print("DB maintenance Store tests: \(tests.count - failedTests) passed, \(failedTests) failed")
    exit(failedTests == 0 ? 0 : 1)
  }
}

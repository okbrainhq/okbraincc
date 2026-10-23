import Foundation

enum DBMaintenanceRunType: String, Codable, Hashable, CaseIterable {
  case dryRun
  case apply
  case vacuum

  var title: String {
    switch self {
    case .dryRun:
      "Dry Run"
    case .apply:
      "Clean up"
    case .vacuum:
      "Vacuum"
    }
  }

  var systemImage: String {
    switch self {
    case .dryRun:
      "eye"
    case .apply:
      "checkmark.circle"
    case .vacuum:
      "arrow.down.circle"
    }
  }

  var scriptName: String {
    switch self {
    case .dryRun:
      "db-maintenance-dry-run.sh"
    case .apply:
      "db-maintenance-apply.sh"
    case .vacuum:
      "db-maintenance-vacuum.sh"
    }
  }
}

enum DBMaintenanceRunStatus: String, Codable, Hashable {
  case running
  case success
  case failed
  case stopped
  case warning
  case incomplete
  case partial
  case deferred

  var title: String {
    switch self {
    case .running:
      "Running"
    case .success:
      "Succeeded"
    case .failed:
      "Failed"
    case .stopped:
      "Stopped / outcome may be partial"
    case .warning:
      "Completed with warnings"
    case .incomplete:
      "Sweep in progress"
    case .partial:
      "Partial / needs attention"
    case .deferred:
      "Deferred / retry next cycle"
    }
  }
}

enum DBMaintenanceTrigger: String, Codable, Hashable {
  case automatic
  case manual
}

struct DBMaintenanceRun: Codable, Hashable, Identifiable {
  let id: UUID
  let runType: DBMaintenanceRunType
  let trigger: DBMaintenanceTrigger
  var startedAt: Date
  var finishedAt: Date?
  var status: DBMaintenanceRunStatus
  var exitCode: Int32?
  var detail: String
  var log: String
  // Optional so existing saved run JSON continues to decode unchanged.
  var configuration: DBMaintenanceConfiguration? = nil
  var report: DBMaintenanceReport? = nil

  var isRunning: Bool {
    status == .running
  }
}

struct DBMaintenanceScheduleSettings: Hashable {
  let isEnabled: Bool
  let intervalMinutes: Int
  let retentionDays: Int

  var intervalHoursComponent: Int {
    intervalMinutes / 60
  }

  var intervalMinuteComponent: Int {
    intervalMinutes % 60
  }

  var intervalLabel: String {
    let hours = intervalHoursComponent
    let minutes = intervalMinuteComponent

    if hours > 0, minutes > 0 {
      return "Every \(hours)h \(minutes)m"
    }

    if hours > 0 {
      return "Every \(hours)h"
    }

    return "Every \(minutes)m"
  }

  func nextAutomaticRunDate(now: Date, lastRunDate: Date?, lastAttemptDate: Date?) -> Date? {
    guard isEnabled else {
      return nil
    }

    // Failed/incomplete work retries in one hour, instead of silently waiting another day.
    // Dry Run/Vacuum are never passed in as a successful cleanup anchor by the Store.
    if let lastAttemptDate, lastRunDate == nil || lastAttemptDate > lastRunDate! {
      return lastAttemptDate.addingTimeInterval(3600)
    }
    return lastRunDate?.addingTimeInterval(86400) ?? now

  }

  func shouldRunAutomatically(
    now: Date,
    lastAttemptDate: Date?,
    lastRunDate: Date?,
    isActive: Bool
  ) -> Bool {
    guard isEnabled, !isActive else {
      return false
    }

    guard let nextDate = nextAutomaticRunDate(
      now: now,
      lastRunDate: lastRunDate,
      lastAttemptDate: lastAttemptDate
    ) else {
      return false
    }

    return now >= nextDate
  }
}

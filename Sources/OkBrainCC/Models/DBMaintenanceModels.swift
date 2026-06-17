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
      "Apply"
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

  var title: String {
    switch self {
    case .running:
      "Running"
    case .success:
      "Succeeded"
    case .failed:
      "Failed"
    case .stopped:
      "Stopped"
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

    let interval = TimeInterval(max(intervalMinutes, 1) * 60)
    let anchors = [lastRunDate, lastAttemptDate].compactMap { $0 }
    guard let anchor = anchors.max() else {
      return now
    }

    return anchor.addingTimeInterval(interval)
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

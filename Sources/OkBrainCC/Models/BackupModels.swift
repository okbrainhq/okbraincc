import Foundation

enum BackupSystemID: String, CaseIterable, Codable, Hashable, Identifiable {
  case prodbox
  case prodboxSandbox

  var id: String {
    rawValue
  }
}

enum BackupOperation: String, Codable, Hashable {
  case backup
  case restore

  var title: String {
    switch self {
    case .backup:
      "Backup"
    case .restore:
      "Restore"
    }
  }
}

enum BackupRunTrigger: String, Codable, Hashable {
  case automatic
  case manual
}

enum BackupRunStatus: String, Codable, Hashable {
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

struct BackupRun: Codable, Hashable, Identifiable {
  let id: UUID
  let systemID: BackupSystemID
  let operation: BackupOperation
  let trigger: BackupRunTrigger
  var startedAt: Date
  var finishedAt: Date?
  var status: BackupRunStatus
  var exitCode: Int32?
  var detail: String
  var log: String

  var isRunning: Bool {
    status == .running
  }
}

enum BackupComponentKind: Hashable {
  case directory
  case database(prefix: String, suffix: String)
}

struct BackupComponentDefinition: Hashable, Identifiable {
  let id: String
  let title: String
  let relativePath: String
  let kind: BackupComponentKind
  let isRequired: Bool
}

struct BackupRestoreOption: Hashable, Identifiable {
  let id: String
  let title: String
  let argument: String?
}

struct BackupSystemDefinition: Hashable, Identifiable {
  let id: BackupSystemID
  let title: String
  let subtitle: String
  let systemImage: String
  let remoteHost: String
  let backupDirectoryName: String
  let backupScriptName: String
  let restoreScriptName: String
  let scheduleHour: Int
  let scheduleMinute: Int
  let components: [BackupComponentDefinition]
  let restoreOptions: [BackupRestoreOption]

  var backupDirectoryURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(backupDirectoryName, isDirectory: true)
  }

  var restoreHistoryDirectoryURL: URL {
    backupDirectoryURL.appendingPathComponent("restore-runs", isDirectory: true)
  }

  var scheduleLabel: String {
    String(format: "%02d:%02d", scheduleHour, scheduleMinute)
  }

  static let all: [BackupSystemDefinition] = [
    .prodbox,
    .prodboxSandbox
  ]

  static func definition(for id: BackupSystemID) -> BackupSystemDefinition {
    all.first { $0.id == id } ?? .prodbox
  }
}

extension BackupSystemDefinition {
  static let prodbox = BackupSystemDefinition(
    id: .prodbox,
    title: "Prodbox",
    subtitle: "prodbox.local",
    systemImage: "server.rack",
    remoteHost: "arunoda@prodbox.local",
    backupDirectoryName: "okbraincc-backups/prodbox",
    backupScriptName: "backup-prodbox.sh",
    restoreScriptName: "restore-prodbox.sh",
    scheduleHour: 3,
    scheduleMinute: 30,
    components: [
      BackupComponentDefinition(
        id: "db",
        title: "Database",
        relativePath: "data/db/brain.db",
        kind: .database(prefix: "brain-", suffix: ".db"),
        isRequired: true
      ),
      BackupComponentDefinition(
        id: "brain-data",
        title: "Brain Data",
        relativePath: "data/brain-data",
        kind: .directory,
        isRequired: true
      ),
      BackupComponentDefinition(
        id: "brain-uploads",
        title: "Brain Uploads",
        relativePath: "data/brain-uploads",
        kind: .directory,
        isRequired: true
      ),
      BackupComponentDefinition(
        id: "brain-sandbox",
        title: "Sandbox Apps",
        relativePath: "data/brain-sandbox/apps",
        kind: .directory,
        isRequired: false
      ),
      BackupComponentDefinition(
        id: "brain-sandbox-skills",
        title: "Sandbox Skills",
        relativePath: "data/brain-sandbox/skills",
        kind: .directory,
        isRequired: false
      ),
      BackupComponentDefinition(
        id: "brain-sandbox-upload-images",
        title: "Sandbox Images",
        relativePath: "data/brain-sandbox/upload-images",
        kind: .directory,
        isRequired: false
      )
    ],
    restoreOptions: [
      BackupRestoreOption(id: "full", title: "Full Restore", argument: nil),
      BackupRestoreOption(id: "db", title: "Database", argument: "--db-only"),
      BackupRestoreOption(id: "data", title: "Brain Data", argument: "--data-only"),
      BackupRestoreOption(id: "uploads", title: "Brain Uploads", argument: "--uploads-only"),
      BackupRestoreOption(id: "sandbox", title: "Sandbox Apps", argument: "--sandbox-only"),
      BackupRestoreOption(id: "sandbox-skills", title: "Sandbox Skills", argument: "--sandbox-skills-only"),
      BackupRestoreOption(id: "sandbox-images", title: "Sandbox Images", argument: "--sandbox-images-only")
    ]
  )

  static let prodboxSandbox = BackupSystemDefinition(
    id: .prodboxSandbox,
    title: "Prodbox Sandbox",
    subtitle: "prodbox-sandbox.local",
    systemImage: "shippingbox",
    remoteHost: "arunoda@prodbox-sandbox.local",
    backupDirectoryName: "okbraincc-backups/prodbox-sandbox",
    backupScriptName: "backup-prodbox-sandbox.sh",
    restoreScriptName: "restore-prodbox-sandbox.sh",
    scheduleHour: 3,
    scheduleMinute: 45,
    components: [
      BackupComponentDefinition(
        id: "apps",
        title: "Apps",
        relativePath: "data/apps",
        kind: .directory,
        isRequired: true
      ),
      BackupComponentDefinition(
        id: "upload_images",
        title: "Upload Images",
        relativePath: "data/upload-images",
        kind: .directory,
        isRequired: true
      ),
      BackupComponentDefinition(
        id: "skills",
        title: "Skills",
        relativePath: "data/skills",
        kind: .directory,
        isRequired: true
      ),
      BackupComponentDefinition(
        id: "brain-data",
        title: "Brain Data",
        relativePath: "data/brain-data",
        kind: .directory,
        isRequired: true
      )
    ],
    restoreOptions: [
      BackupRestoreOption(id: "full", title: "Full Restore", argument: nil),
      BackupRestoreOption(id: "apps", title: "Apps", argument: "--apps-only"),
      BackupRestoreOption(id: "upload-images", title: "Upload Images", argument: "--images-only"),
      BackupRestoreOption(id: "skills", title: "Skills", argument: "--skills-only"),
      BackupRestoreOption(id: "brain-data", title: "Brain Data", argument: "--data-only")
    ]
  )
}

struct BackupComponentStatus: Hashable, Identifiable {
  let id: String
  let title: String
  let isRequired: Bool
  let latestDate: String?
  let snapshotCount: Int
  let size: String
  let isCurrentToday: Bool
  let path: String
}

struct BackupSystemStatus: Hashable {
  let systemID: BackupSystemID
  let backupDirectoryPath: String
  let backupDirectoryExists: Bool
  let requiredComponentsAreCurrent: Bool
  let latestCompletionDate: Date?
  let components: [BackupComponentStatus]
  let recentErrors: [String]
  let backupLogTail: String
  let stdoutLogTail: String
  let stderrLogTail: String
}

struct BackupScheduleSettings: Hashable {
  let isEnabled: Bool
  let intervalMinutes: Int
  let retentionCount: Int

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

  func nextAutomaticBackupDate(now: Date, lastBackupDate: Date?, lastAttemptDate: Date?) -> Date? {
    guard isEnabled else {
      return nil
    }

    let interval = TimeInterval(max(intervalMinutes, 1) * 60)
    let anchors = [lastBackupDate, lastAttemptDate].compactMap { $0 }
    guard let anchor = anchors.max() else {
      return now
    }

    return anchor.addingTimeInterval(interval)
  }

  func shouldRunAutomatically(
    now: Date,
    lastAttemptDate: Date?,
    lastBackupDate: Date?,
    isActive: Bool
  ) -> Bool {
    guard isEnabled, !isActive else {
      return false
    }

    guard let nextBackupDate = nextAutomaticBackupDate(
      now: now,
      lastBackupDate: lastBackupDate,
      lastAttemptDate: lastAttemptDate
    ) else {
      return false
    }

    return now >= nextBackupDate
  }
}

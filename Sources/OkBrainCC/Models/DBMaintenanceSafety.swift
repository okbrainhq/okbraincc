import Foundation

struct DBMaintenanceSafetySettings: Codable, Hashable {
  var database = "/var/www/brain/brain.db"
  // Legacy decoding stays truthful for persisted audits. The Store owns v2 defaults/migration.
  static let defaultUploadsDirectory = "/var/www/brain-data/uploads"
  var uploadsDirectory = ""
  var writerServices = "brain"
  var deleteImages = false
  var downtimeAcknowledged = false
  var writersAcknowledged = false
  var externalReferencesAcknowledged = false

  init() {}

  private enum CodingKeys: String, CodingKey {
    case database, uploadsDirectory, writerServices, deleteImages
    case downtimeAcknowledged, writersAcknowledged, externalReferencesAcknowledged
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    database = try values.decodeIfPresent(String.self, forKey: .database) ?? database
    uploadsDirectory = try values.decodeIfPresent(String.self, forKey: .uploadsDirectory) ?? ""
    writerServices = try values.decodeIfPresent(String.self, forKey: .writerServices) ?? "brain"
    deleteImages = try values.decodeIfPresent(Bool.self, forKey: .deleteImages) ?? false
    downtimeAcknowledged = try values.decodeIfPresent(Bool.self, forKey: .downtimeAcknowledged) ?? false
    writersAcknowledged = try values.decodeIfPresent(Bool.self, forKey: .writersAcknowledged) ?? false
    externalReferencesAcknowledged = try values.decodeIfPresent(Bool.self, forKey: .externalReferencesAcknowledged) ?? false
  }

  mutating func revokeVacuumConsent() {
    downtimeAcknowledged = false
    writersAcknowledged = false
  }
}

/// Frozen once at the start of a Dry Run → Apply/Vacuum pair, including its cursor.
struct DBMaintenanceConfiguration: Codable, Hashable {
  let remoteHost: String
  let retentionDays: Int
  let safety: DBMaintenanceSafetySettings
  var imageAfterID: String = ""
  // Nil on old runs means the historical preview/offline policy, never the new online policy.
  var imagePolicyVersion: Int? = nil
  var scheduleIntervalMinutes: Int? = nil
  var scheduleEnabled: Bool? = nil

  var imageMode: String {
    safety.deleteImages ? (imagePolicyVersion == 2 ? "online-apply" : "apply") : "preview"
  }

  var sweepKey: String {
    var scope = [remoteHost, safety.database, safety.uploadsDirectory, String(retentionDays), imageMode]
    if let imagePolicyVersion { scope.insert("image-policy-v\(imagePolicyVersion)", at: 0) }
    return (try? JSONEncoder().encode(scope).base64EncodedString()) ?? ""
  }

  var environment: [String: String] {
    let prefix = "OKBRAINCC_DB_MAINTENANCE_"
    return Dictionary(uniqueKeysWithValues: [
      ("REMOTE_HOST", remoteHost), ("RETENTION_DAYS", String(retentionDays)),
      ("DATABASE", safety.database), ("UPLOADS_DIRECTORY", safety.uploadsDirectory),
      ("WRITER_SERVICES", safety.writerServices), ("DELETE_IMAGES", safety.deleteImages ? "1" : "0"),
      ("DOWNTIME_ACKNOWLEDGED", safety.downtimeAcknowledged ? "1" : "0"),
      ("WRITERS_ACKNOWLEDGED", safety.writersAcknowledged ? "1" : "0"),
      ("AFTER_ID", imageAfterID)
    ].map { (prefix + $0.0, $0.1) })
  }

  func validationError(for type: DBMaintenanceRunType) -> String? {
    func matches(_ string: String, _ pattern: String) -> Bool {
      string.range(of: pattern, options: .regularExpression) != nil
    }
    func pathIsValid(_ path: String) -> Bool {
      path.hasPrefix("/") && path != "/" && path.count <= 1024 &&
        path == path.trimmingCharacters(in: .whitespacesAndNewlines) &&
        !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
        !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }
    guard matches(remoteHost, "^(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*$") else {
      return "Use an SSH alias or user@hostname, without options, ports, whitespace or shell syntax."
    }
    guard (1...365).contains(retentionDays), pathIsValid(safety.database),
          safety.uploadsDirectory.isEmpty || pathIsValid(safety.uploadsDirectory) else {
      return "Use explicit absolute database/uploads paths (no dot components) and 1–365 retention days."
    }
    if safety.deleteImages && safety.uploadsDirectory.isEmpty {
      return "Image cleanup requires an uploads directory. Use the source default or an existing custom storage_root."
    }
    // Online Apply never validates/uses offline writer permissions or legacy image acknowledgements.
    if type == .vacuum {
      let services = safety.writerServices.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      guard services.count <= 20, Set(services).count == services.count,
            services.allSatisfy({ matches($0, "^[A-Za-z0-9][A-Za-z0-9_.@-]{0,100}$") }) else {
        return "Enter distinct documented systemd writer service names for manual Vacuum, separated by spaces."
      }
      guard !services.isEmpty, safety.downtimeAcknowledged, safety.writersAcknowledged else {
        return "Manual Vacuum requires downtime permission and affirmation that ALL app/worker/filesystem writers are controlled by the configured services."
      }
    }
    return nil
  }
}

struct DBMaintenanceImageSummary: Codable, Hashable {
  let mode: String
  let batches: Int
  let examined: Int
  let candidates: Int
  let candidateBytes: Int64
  let deleted: Int
  let deletedBytes: Int64
  let missingFinalized: Int
  let errors: Int
  let reasons: [String: Int]
  let nextAfterID: String?
  let sweepComplete: Bool
  let cursorCanAdvance: Bool
  var unconfirmedBatch: Bool? = nil
}

struct DBMaintenanceReport: Codable, Hashable {
  let outcome: String
  let history: String
  let images: DBMaintenanceImageSummary?
  let restorationFailed: Bool
  let partial: Bool
  let error: String?

  static func parse(_ output: String) -> Self? {
    guard let line = output.components(separatedBy: "\n").last(where: { $0.hasPrefix("CC_RESULT ") }),
          let data = String(line.dropFirst("CC_RESULT ".count)).data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }

  func status(exitCode: Int32) -> DBMaintenanceRunStatus {
    if restorationFailed { return partial ? .partial : .failed }
    if outcome == "deferred" { return .deferred }
    if exitCode != 0 {
      if outcome == "stopped" { return .stopped }
      return partial || outcome == "partial" ? .partial : .failed
    }
    switch outcome {
    case "success": return .success
    case "warning": return .warning
    case "incomplete": return .incomplete
    default: return .failed
    }
  }

  var permitsApply: Bool {
    ["success", "warning", "incomplete"].contains(outcome) &&
      history == "dry_run_zero_deletions" && !partial && !restorationFailed
  }
}

import SwiftUI

struct DBMaintenanceView: View {
  @ObservedObject private var store = DBMaintenanceStore.shared
  @State private var selectedRunID: UUID?
  @State private var isShowingSettings = false
  @State private var isConfirmingVacuum = false
  @State private var vacuumConfirmText = ""

  private var isRunning: Bool {
    store.activeRunID != nil
  }

  private var selectedRun: DBMaintenanceRun? {
    runs.first { $0.id == selectedRunID }
  }

  private var runs: [DBMaintenanceRun] {
    store.runs
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        if let error = store.persistenceError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }

        HStack(alignment: .top, spacing: 18) {
          runsList
            .frame(width: 280)

          selectedRunDetail
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      ensureSelection()
    }
    .onChange(of: runs) {
      ensureSelection()
    }
    .sheet(isPresented: $isShowingSettings) {
      DBMaintenanceSettingsView(store: store)
    }
    .alert("Vacuum Database", isPresented: $isConfirmingVacuum) {
      TextField("Type CONFIRM", text: $vacuumConfirmText)
      Button("Run Vacuum", role: .destructive) {
        if let runID = store.runVacuumWithDryRun() {
          selectedRunID = runID
        }
        vacuumConfirmText = ""
      }
      .disabled(vacuumConfirmText != "CONFIRM")
      Button("Cancel", role: .cancel) {
        vacuumConfirmText = ""
      }
    } message: {
      Text("Vacuum is manual only and requires a planned downtime window. Configured writers (\(store.safety.writerServices)) must cover ALL app/worker/filesystem writers. Only previously active services will be restored. Images are preview-only during Vacuum; normal Apply handles online image cleanup.\n\nType CONFIRM to proceed.")
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("DB Maintenance")
            .font(.title2.weight(.semibold))

          TimelineView(.periodic(from: .now, by: 60)) { timeline in
            Text("\(store.remoteHost) · \(store.nextRunCountdownLabel)")
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        statusBadge
      }

      HStack(spacing: 10) {
        Button {
          if let runID = store.runMaintenance(type: .dryRun) {
            selectedRunID = runID
          }
        } label: {
          Label("Dry Run", systemImage: "eye")
        }
        .buttonStyle(.borderedProminent)
        .disabled(isRunning)
        .accessibilityLabel("Dry Run")

        Button {
          selectedRunID = store.runApplyWithDryRun()
        } label: {
          Label(store.safety.deleteImages ? "Apply + Images (online)" : "Apply History", systemImage: "checkmark.circle")
        }
        .disabled(isRunning)
        .accessibilityLabel("Apply")

        Button {
          isConfirmingVacuum = true
        } label: {
          Label("Vacuum", systemImage: "arrow.down.circle")
        }
        .disabled(isRunning)
        .accessibilityLabel("Vacuum")

        if isRunning {
          Button(role: .destructive) {
            store.stopRun()
          } label: {
            Label("Stop", systemImage: "stop.fill")
          }
          .accessibilityLabel("Stop")
        }

        Button {
          isShowingSettings = true
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .accessibilityLabel("Settings")

        Button {
          store.refreshRuns()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh maintenance runs")
        .accessibilityLabel("Refresh")

        if isRunning {
          ProgressView()
            .controlSize(.small)
        }
      }

      Text("cleanup-old-execution-history.sh --tool-history-only --days \(store.schedule.retentionDays)")
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Text(store.safety.deleteImages
           ? "Automatic online image cleanup · \(store.schedule.intervalLabel) when enabled · older than \(store.schedule.retentionDays) days. Brain is not stopped. No automatic Vacuum."
           : "Image cleanup disabled in Settings; previews remain available. Apply cleans history online without stopping Brain. No automatic Vacuum.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Text(store.imageProgressLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var statusBadge: some View {
    if let lastRun = runs.first(where: { $0.status != .running }) {
      Label(
        lastRun.status == .success ? "Last run succeeded" : "Last Run \(lastRun.status.title)",
        systemImage: lastRun.status == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
      )
      .foregroundStyle(lastRun.status == .success ? .green : .orange)
    } else {
      Label("No Runs Yet", systemImage: "questionmark.circle")
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Runs List

  private var runsList: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Maintenance Runs")
        .font(.headline)

      if runs.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "tray")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("No maintenance runs yet")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
      } else {
        List(selection: $selectedRunID) {
          ForEach(runs) { run in
            DBMaintenanceRunRow(run: run)
              .tag(run.id)
          }
        }
        .frame(minHeight: 220, idealHeight: 320, maxHeight: 420)
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  // MARK: - Detail

  @ViewBuilder
  private var selectedRunDetail: some View {
    if let selectedRun {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
              Image(systemName: selectedRun.runType.systemImage)
              Text(selectedRun.runType.title)
                .font(.title3.weight(.semibold))
            }
            Text("\(selectedRun.trigger == .automatic ? "Automatic" : "Manual") · \(selectedRun.status.title) · \(Self.timeFormatter.string(from: selectedRun.startedAt))")
              .foregroundStyle(.secondary)
          }

          Spacer()

          if let exitCode = selectedRun.exitCode {
            Text("exit \(exitCode)")
              .font(.callout.monospaced())
              .foregroundStyle(exitCode == 0 ? .green : .red)
          }
        }

        if let finishedAt = selectedRun.finishedAt {
          let duration = finishedAt.timeIntervalSince(selectedRun.startedAt)
          Text("Duration: \(Self.durationFormatter.string(from: duration) ?? "\(Int(duration))s")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let configuration = selectedRun.configuration {
          Text("Frozen scope: \(configuration.remoteHost) · \(configuration.safety.database) · \(configuration.retentionDays) days")
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        if let report = selectedRun.report {
          DBMaintenanceReportView(report: report)
        } else if !selectedRun.isRunning {
          Text("Legacy run or missing terminal report: no structured removal totals available. See logs.")
            .foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 10) {
          Text("Persistent phase logs · metadata only")
            .font(.headline)

          ScrollView {
            Text(store.logText(for: selectedRun.id))
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .padding(12)
          }
          .frame(minHeight: 180, idealHeight: 240, maxHeight: 320)
          .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
      }
    } else {
      ContentUnavailableView("No Runs", systemImage: "tray")
        .frame(maxWidth: .infinity, minHeight: 320)
    }
  }

  // MARK: - Helpers

  private func ensureSelection() {
    if let selectedRunID, runs.contains(where: { $0.id == selectedRunID }) {
      return
    }

    selectedRunID = runs.first?.id
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()

  private static let durationFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 3
    return formatter
  }()
}

// MARK: - Run Row

private struct DBMaintenanceRunRow: View {
  let run: DBMaintenanceRun

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: iconName)
        .foregroundStyle(color)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 2) {
        Text(run.runType.title)
          .lineLimit(1)
        Text("\(run.trigger == .automatic ? "Auto" : "Manual") · \(run.status.title) · \(Self.timeFormatter.string(from: run.startedAt))")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()
    }
    .padding(.vertical, 4)
  }

  private var iconName: String {
    if run.isRunning {
      return "clock.arrow.circlepath"
    }

    switch run.status {
    case .running:
      return "clock.arrow.circlepath"
    case .success:
      return "checkmark.circle.fill"
    case .failed:
      return "xmark.circle.fill"
    case .stopped:
      return "stop.circle.fill"
    case .warning, .incomplete, .partial, .deferred:
      return "exclamationmark.triangle.fill"
    }
  }

  private var color: Color {
    switch run.status {
    case .running:
      .blue
    case .success:
      .green
    case .failed:
      .red
    case .stopped, .warning, .incomplete, .partial, .deferred:
      .orange
    }
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()
}

// MARK: - Settings Sheet

private struct DBMaintenanceSettingsView: View {
  @ObservedObject var store: DBMaintenanceStore

  @Environment(\.dismiss) private var dismiss
  @State private var editingRemoteHost: String = ""
  @State private var draft = DBMaintenanceSafetySettings()
  @State private var validationError: String?

  private var schedule: DBMaintenanceScheduleSettings {
    store.schedule
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text("DB Maintenance Settings")
              .font(.title2.weight(.semibold))
            Text(store.remoteHost)
              .foregroundStyle(.secondary)
          }

          Spacer()

          Button("Save & Done") {
            validationError = store.updateConfiguration(host: editingRemoteHost, safety: draft)
            if validationError == nil { dismiss() }
          }
          .keyboardShortcut(.defaultAction)
          .accessibilityLabel("Done")
        }

        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 6) {
            Text("SSH Host")
              .foregroundStyle(.secondary)
            TextField("user@host.local", text: Binding(
              get: { editingRemoteHost },
              set: { editingRemoteHost = $0; draft.revokeVacuumConsent() }
            ))
              .textFieldStyle(.roundedBorder)
              .font(.callout.monospaced())
          }

          Toggle(
            "Run automatically",
            isOn: Binding(
              get: { schedule.isEnabled },
              set: { store.updateSchedule(isEnabled: $0) }
            )
          )
          .toggleStyle(.checkbox)

          HStack(spacing: 12) {
            Picker(
              "Hours",
              selection: Binding(
                get: { schedule.intervalHoursComponent },
                set: { updateInterval(hours: $0) }
              )
            ) {
              ForEach(0...24, id: \.self) { hour in
                Text(String(format: "%02d", hour)).tag(hour)
              }
            }
            .frame(width: 130)

            Picker(
              "Minutes",
              selection: Binding(
                get: { schedule.intervalMinuteComponent },
                set: { updateInterval(minutes: $0) }
              )
            ) {
              ForEach(0..<60, id: \.self) { minute in
                Text(String(format: "%02d", minute)).tag(minute)
              }
            }
            .frame(width: 140)
          }

          Stepper(
            value: Binding(
              get: { schedule.retentionDays },
              set: { store.updateSchedule(retentionDays: $0) }
            ),
            in: 1...365
          ) {
            Text("History / audit retention and minimum image age: \(schedule.retentionDays) days")
          }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

        imageSafetySettings
        vacuumSafetySettings
        if let validationError {
          Text(validationError).foregroundStyle(.red)
        }
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
          GridRow {
            Text("Next Run")
              .foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 60)) { _ in
              Text(store.nextRunCountdownLabel)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            }
          }
          settingsRow("Interval", schedule.intervalLabel)
          settingsRow("Runner", "In-app timer")
          settingsRow("Retention", "\(schedule.retentionDays) days")
          settingsRow("Default Host", "arunoda@prodbox.local")
          settingsRow("Dry-Run Script", "db-maintenance-dry-run.sh")
          settingsRow("Apply Script", "db-maintenance-apply.sh")
          settingsRow("Vacuum Script", "db-maintenance-vacuum.sh")
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

        Spacer()
      }
      .padding(24)
    }
    .frame(minWidth: 680, minHeight: 520)
    .onAppear {
      editingRemoteHost = store.remoteHost
      draft = store.safety
    }
  }

  private var imageSafetySettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Automatic online agent-image cleanup").font(.headline)
      Text("The existing scheduled Dry Run → Apply cleans tool history and eligible agent images while Brain stays online. Default: every 24 hours, older than 10 days. No extra permission, confirmation, service check or downtime is needed for normal Apply.")
        .font(.callout).foregroundStyle(.secondary)
      TextField("Existing remote app database", text: vacuumScopeBinding(\.database))
        .textFieldStyle(.roundedBorder)
      TextField("Canonical uploads directory (blank uses source default)", text: $draft.uploadsDirectory)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("maintenance.uploadsDirectory")
      Text("Default: /var/www/brain-data/uploads. Existing custom paths are preserved. Unavailable roots fail safely; the backend must match each image's recorded storage_root and hash before deletion. Paths are passed as argv, never shell commands.")
        .font(.caption).foregroundStyle(.secondary)
      Toggle("Clean eligible agent images during scheduled and manual Apply (online)", isOn: $draft.deleteImages)
        .accessibilityIdentifier("maintenance.deleteImages")
      Text("Enabled for new installs and migrated legacy preview-only settings. You can disable image deletion here; later launches preserve that choice. Dry Run always has zero actual deletions. Apply requires the released Brain --online CLI and provenance schema; incompatible backends are blocked, never run offline instead.")
        .font(.caption).foregroundStyle(.secondary)
      Text("Both the upload and its owning chat / recent activity must be older than \(schedule.retentionDays) days, with no active jobs. The backend protects user uploads, unknown/legacy, pinned, shared and retained-reference images. Conversations, messages and repository files are never deletion targets.")
        .font(.caption).foregroundStyle(.secondary)
      Text("Bounded sweeps: at most 3 × 100 rows per phase, plus a separate 100-row read-only pre-Apply probe. Preview and online deletion have separate persisted cursors. Incomplete sweeps resume on later runs; a busy or changed online snapshot defers unprocessed work to the next cycle. Dry Run is a preview, not a frozen deletion manifest.")
        .font(.caption).foregroundStyle(.secondary)
      Text("Schedule changes above save immediately. Other settings save with Save & Done. Active Dry Run → Apply pairs keep their frozen settings.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .toggleStyle(.checkbox)
    .padding(16)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
  }

  private var vacuumSafetySettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Manual Vacuum only — offline safety").font(.headline)
      Text("Vacuum is separate, never scheduled or run on startup. It requires manual confirmation and stops configured writers for compaction, then restores only previously active services. Images are preview-only during Vacuum. These settings do not affect normal online Apply.")
        .font(.callout).foregroundStyle(.secondary)
      TextField("All writer services for Vacuum (space-separated)", text: vacuumScopeBinding(\.writerServices))
        .textFieldStyle(.roundedBorder)
      Text("Default: brain (matching existing sudoers). Include all app/worker/filesystem writers; extra services require reviewed stop/start permissions. Changing host, database or services clears only Vacuum acknowledgements, not online image cleanup.")
        .font(.caption).foregroundStyle(.secondary)
      Toggle("I authorize downtime for manual Vacuum.", isOn: $draft.downtimeAcknowledged)
      Toggle("ALL app/worker/filesystem writers are controlled by these services; no uncontrolled writer can restart or write during Vacuum.", isOn: $draft.writersAcknowledged)
    }
    .toggleStyle(.checkbox)
    .padding(16)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
  }

  private func vacuumScopeBinding(_ key: WritableKeyPath<DBMaintenanceSafetySettings, String>) -> Binding<String> {
    Binding(get: { draft[keyPath: key] }, set: {
      draft[keyPath: key] = $0
      draft.revokeVacuumConsent()
    })
  }

  private func updateInterval(hours: Int? = nil, minutes: Int? = nil) {
    let nextHours = min(max(hours ?? schedule.intervalHoursComponent, 0), 24)
    let nextMinutes = min(max(minutes ?? schedule.intervalMinuteComponent, 0), 59)
    let totalMinutes = min(max((nextHours * 60) + nextMinutes, 60), 24 * 60)
    store.updateSchedule(intervalMinutes: totalMinutes)
  }

  private func settingsRow(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.monospaced())
        .textSelection(.enabled)
    }
  }
}


private struct DBMaintenanceReportView: View {
  let report: DBMaintenanceReport

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Removal report").font(.headline)
      Text(historyLabel)
      Text("History tables in the log are pre-Apply candidate rows / approximate payload. News-search rows overlap tool-history rows; totals are not summed.")
        .font(.caption).foregroundStyle(.secondary)
      if let images = report.images {
        Text("Images \(images.mode) · \(images.examined) examined in \(images.batches) batches")
        Text("Candidates: \(images.candidates) files / \(images.candidateBytes) bytes")
        Text("Confirmed reported deletions: \(images.deleted) files / \(images.deletedBytes) bytes; missing finalized: \(images.missingFinalized); per-file errors: \(images.errors)")
        if images.unconfirmedBatch == true {
          Text("Unconfirmed image changes: interrupted/invalid batch or unlink without a confirmed tombstone commit. Totals above include confirmed commits only; retry keeps unfinalized provenance.")
            .foregroundStyle(.red)
        }
        Text(images.sweepComplete ? "End of this traversal reached; protected/error rows are rechecked next sweep." :
          "Sweep INCOMPLETE. Resume after \(images.nextAfterID ?? "start"). This is not a full-upload cleanup claim.")
          .foregroundStyle(images.sweepComplete ? Color.secondary : Color.orange)
        ForEach(images.reasons.keys.sorted(), id: \.self) { reason in
          Text("\(reason): \(images.reasons[reason] ?? 0)")
            .font(.caption.monospaced())
        }
      } else {
        Text("No completed image sweep. See phase logs for unavailable/blocked/probe details.")
          .foregroundStyle(.orange)
      }
      if report.restorationFailed {
        Text("SERVICE RESTORATION FAILED — operator intervention required.")
          .foregroundStyle(.red).bold()
      }
      if report.outcome == "deferred" {
        Text("Online image cleanup deferred. No confirmed image deletions or unconfirmed unlinks were reported. The cursor stays unchanged; retry next scheduled cycle. History may have completed.")
          .foregroundStyle(.orange)
      }
      if report.partial { Text("Partial result: some work may have committed.").foregroundStyle(.orange) }
      if let error = report.error { Text(error).font(.caption.monospaced()).foregroundStyle(.red) }
    }
    .textSelection(.enabled)
    .padding(12)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
  }

  private var historyLabel: String {
    switch report.history {
    case "dry_run_zero_deletions": return "History Dry Run: actual deletions = 0."
    case "apply_succeeded_actual_counts_unavailable": return "History Apply command succeeded. Actual deleted rows/bytes are not supplied by the counterpart."
    case "apply_started_actual_counts_unavailable": return "History Apply started; actual changes are unknown / possibly partial."
    default: return "History not completed. See phase logs."
    }
  }
}

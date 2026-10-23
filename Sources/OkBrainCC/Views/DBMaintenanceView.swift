import SwiftUI

@MainActor
struct DBMaintenanceView: View {
  @ObservedObject private var store: DBMaintenanceStore
  @State private var showingSettings = false
  @State private var confirmingVacuum = false
  @State private var selectedRunID: UUID?

  init(store: DBMaintenanceStore? = nil) {
    self.store = store ?? .shared
  }

  private var activeRun: DBMaintenanceRun? { store.runs.first { $0.id == store.activeRunID } }
  private var selectedRun: DBMaintenanceRun? { store.runs.first { $0.id == selectedRunID } }
  private var isRunning: Bool { store.activeRunID != nil }
  private var cleanupRunning: Bool { isRunning && activeRun?.runType != .vacuum }
  private var vacuumRunning: Bool { activeRun?.runType == .vacuum }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        if let error = store.persistenceError {
          Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        // Logs have a large intrinsic width. ViewThatFits measures that ideal width
        // and incorrectly stacks the entire run list above the logs, even in a wide
        // window. Keep the same two-column layout as Backup DB and let text wrap.
        HStack(alignment: .top, spacing: 18) {
          runList.frame(width: 200)
          runDetail
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("maintenance.runDetail")
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear { ensureSelection() }
    .onChange(of: store.runs.map(\.id)) { ensureSelection() }
    .onChange(of: store.activeRunID) {
      if let id = store.activeRunID { selectedRunID = id }
    }
    .sheet(isPresented: $showingSettings) { DBMaintenanceSettingsView(store: store) }
    .alert("Vacuum Database?", isPresented: $confirmingVacuum) {
      Button("Cancel", role: .cancel) {}
      Button("Run Vacuum") { selectedRunID = store.runVacuum(confirmed: true) }
    } message: {
      Text("On \(store.remoteHost), this temporarily stops \(store.safety.writerServices) and restores previously running services afterward. Confirm these services cover all database writers and downtime is OK. Vacuum reclaims disk space; it does not delete chats or run retention cleanup.")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("DB Maintenance").font(.title2.weight(.semibold))
          TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text("\(store.remoteHost) · \(isRunning ? "Maintenance in progress" : store.nextRunCountdownLabel)")
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        if let run = activeRun ?? store.runs.first {
          Label(store.isStopping ? "Stopping…" : run.status.title, systemImage: run.status.symbol)
            .foregroundStyle(run.status.color)
            .font(.callout)
        }
      }

      // Exactly three primary actions. Each running operation replaces its own start button.
      HStack(spacing: 10) {
        Button { showingSettings = true } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .accessibilityIdentifier("maintenance.settings")

        Button(role: cleanupRunning ? .destructive : nil) {
          if cleanupRunning { store.stopRun() }
          else { selectedRunID = store.runCleanup() }
        } label: {
          Label(cleanupRunning ? (store.isStopping ? "Stopping…" : "Stop") : "Start Manually",
                systemImage: cleanupRunning ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(vacuumRunning || (cleanupRunning && store.isStopping))
        .accessibilityIdentifier("maintenance.cleanup")
        .help(cleanupRunning ? "Stop maintenance safely" : "Check, clean up expired items, optimize and checkpoint now")

        Button(role: vacuumRunning ? .destructive : nil) {
          if vacuumRunning { store.stopRun() }
          else { confirmingVacuum = true }
        } label: {
          Label(vacuumRunning ? (store.isStopping ? "Stopping…" : "Stop") : "Vacuum",
                systemImage: vacuumRunning ? "stop.fill" : "arrow.down.circle")
        }
        .disabled(cleanupRunning || (vacuumRunning && store.isStopping))
        .accessibilityIdentifier("maintenance.vacuum")
        .help(vacuumRunning ? "Stop Vacuum and restore previously running services" : "Reclaim database disk space (manual only)")

        if isRunning { ProgressView().controlSize(.small) }
      }

      Text("Expire Code Project tool logs & images and web-search logs after \(store.schedule.retentionDays) days. All chat text is kept forever.")
        .font(.callout).foregroundStyle(.secondary)
    }
  }

  private var runList: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Maintenance Runs").font(.headline)
      if store.runs.isEmpty {
        Text("No runs yet")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 220)
          .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
      } else {
        List(selection: $selectedRunID) {
          ForEach(store.runs) { run in
            HStack(spacing: 10) {
              Image(systemName: run.status.symbol).foregroundStyle(run.status.color).frame(width: 16)
              VStack(alignment: .leading, spacing: 3) {
                Text(run.runType.title).fontWeight(.medium)
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                  .font(.caption).foregroundStyle(.secondary)
                Text("\(run.trigger == .automatic ? "Automatic" : "Manual") · \(run.status.title)")
                  .font(.caption).foregroundStyle(.secondary).lineLimit(2)
              }
            }
            .padding(.vertical, 4)
            .tag(run.id)
          }
        }
        .frame(minHeight: 220, idealHeight: 360, maxHeight: 460)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("maintenance.runs")
      }
    }
  }

  @ViewBuilder private var runDetail: some View {
    if let run = selectedRun {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text(run.runType.title).font(.title3.weight(.semibold))
          Spacer()
          TimelineView(.periodic(from: .now, by: run.isRunning ? 1 : 60)) { timeline in
            let seconds = max(0, Int((run.finishedAt ?? timeline.date).timeIntervalSince(run.startedAt)))
            Text("\(seconds / 60)m \(seconds % 60)s\(run.isRunning ? " elapsed" : "")")
              .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
        VStack(alignment: .leading, spacing: 5) {
          Label(run.status.title, systemImage: run.status.symbol).foregroundStyle(run.status.color)
          if let config = run.configuration {
            Text("\(config.remoteHost) · \(run.trigger == .automatic ? "Automatic" : "Manual")\(run.runType == .vacuum ? "" : " · \(config.retentionDays)-day retention")")
              .font(.caption.monospaced()).textSelection(.enabled)
          }
          if let code = run.exitCode { Text("Exit code: \(code)").font(.caption).foregroundStyle(.secondary) }
          if run.isRunning {
            Text(store.isStopping ? "Waiting for safe shutdown. Do not force-quit CC." : "Live progress below; final counts appear when this run finishes.")
              .font(.caption).foregroundStyle(.secondary)
          }
          if let report = run.report { reportSummary(report) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

        VStack(alignment: .leading, spacing: 10) {
          Text(run.isRunning ? "Live Logs" : "Logs").font(.headline)
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                Text(run.log.isEmpty ? "Waiting for output…" : run.log)
                  .font(.system(.caption, design: .monospaced))
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .topLeading)
                Color.clear.frame(height: 1).id("log-end")
              }.padding(12)
            }
            .onChange(of: run.log) { if run.isRunning { proxy.scrollTo("log-end", anchor: .bottom) } }
          }
          .frame(minHeight: 200, idealHeight: 300, maxHeight: 420)
          .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
          .accessibilityIdentifier("maintenance.logs")
        }
      }
    } else {
      ContentUnavailableView("No Maintenance Runs", systemImage: "externaldrive.badge.clock",
                             description: Text("Start manually or enable daily maintenance in Settings. Run details and logs appear here."))
        .frame(maxWidth: .infinity, minHeight: 320)
    }
  }

  @ViewBuilder private func reportSummary(_ report: DBMaintenanceReport) -> some View {
    if let counts = report.historyCounts, !counts.isEmpty {
      Text("\(counts.values.reduce(0) { $0 + $1.deleted }) tool-history records removed or cleared.")
    }
    if let images = report.images {
      Text("\(images.deleted) images removed · \(ByteCountFormatter.string(fromByteCount: images.deletedBytes, countStyle: .file)) reclaimed")
      Text("\(images.examined) images examined · \(images.reasons.values.reduce(0, +)) protected or skipped")
        .font(.caption).foregroundStyle(.secondary)
      if images.errors > 0 || !images.sweepComplete || images.unconfirmedBatch == true {
        Text("Image cleanup needs another pass. See logs for protection reasons or errors.").foregroundStyle(.orange)
      }
    }
    if report.databaseCheck == "ok" {
      Text(report.compaction == "vacuum" ? "Database checked and vacuumed." :
            report.compaction == "optimize-passive-checkpoint" ? "Database checked, optimized and checkpointed." : "Database check passed.")
        .font(.caption).foregroundStyle(.secondary)
    }
    if report.restorationFailed {
      Text("Service restart failed — restore the configured writers manually.").foregroundStyle(.red)
    }
    if let error = report.error {
      Text(error).font(.caption.monospaced()).foregroundStyle(.orange).textSelection(.enabled)
    }
  }

  private func ensureSelection() {
    if let id = selectedRunID, store.runs.contains(where: { $0.id == id }) { return }
    selectedRunID = store.activeRunID ?? store.runs.first?.id
  }
}

@MainActor
private struct DBMaintenanceSettingsView: View {
  @ObservedObject var store: DBMaintenanceStore
  @Environment(\.dismiss) private var dismiss
  @State private var host: String
  @State private var enabled: Bool
  @State private var retentionDays: Int
  @State private var safety: DBMaintenanceSafetySettings
  @State private var error: String?

  init(store: DBMaintenanceStore) {
    self.store = store
    _host = State(initialValue: store.remoteHost)
    _enabled = State(initialValue: store.schedule.isEnabled)
    _retentionDays = State(initialValue: store.schedule.retentionDays)
    _safety = State(initialValue: store.safety)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("DB Maintenance Settings").font(.title2.weight(.semibold))
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text("SSH Host").foregroundStyle(.secondary)
            TextField("user@hostname or SSH alias", text: $host)
              .textFieldStyle(.roundedBorder).font(.callout.monospaced())
              .accessibilityIdentifier("maintenance.host")
            Text("The database server, reachable from the machine running OKBrainCC.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Toggle("Automatic daily maintenance", isOn: $enabled)
            .toggleStyle(.switch).accessibilityIdentifier("maintenance.enabled")
          Stepper(value: $retentionDays, in: 1...365) {
            Text("Delete items older than \(retentionDays) days")
          }
          .accessibilityIdentifier("maintenance.retentionDays")
          Text("Code Project tool logs and images, plus web-search tool logs. All chat text is always kept.")
            .font(.callout).foregroundStyle(.secondary)
          Divider()
          Text("Daily: check the database, clean up, optimize and checkpoint. Full Vacuum is manual only.")
            .font(.callout)
          Text("Leave OKBrainCC running. Missed runs catch up on launch or wake; failed runs retry hourly. Changes apply to future runs, not a run already in progress.")
            .font(.caption).foregroundStyle(.secondary)

          DisclosureGroup("Advanced paths & Vacuum services") {
            VStack(alignment: .leading, spacing: 12) {
              settingField("Database path", text: $safety.database)
              settingField("Uploads directory", text: $safety.uploadsDirectory)
              settingField("Writer services (Vacuum only)", text: $safety.writerServices)
              Text("Space-separated systemd services. Vacuum asks for downtime confirmation each time.")
                .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 10)
          }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
      }
      if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") {
          if let message = store.updateConfiguration(host: host, safety: safety) { error = message; return }
          store.updateSchedule(isEnabled: enabled, retentionDays: retentionDays)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("maintenance.saveSettings")
      }
    }
    .padding(24)
    .frame(width: 560, height: 560)
  }

  private func settingField(_ title: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      TextField(title, text: text).textFieldStyle(.roundedBorder).font(.callout.monospaced())
    }
  }
}

private extension DBMaintenanceRunStatus {
  var color: Color {
    switch self {
    case .running: .blue
    case .success: .green
    case .failed: .red
    default: .orange
    }
  }
  var symbol: String {
    switch self {
    case .running: "clock.arrow.circlepath"
    case .success: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .stopped: "stop.circle.fill"
    default: "exclamationmark.triangle.fill"
    }
  }
}

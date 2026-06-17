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
      Text("Vacuum rewrites the entire database and blocks the app. The brain service will be stopped during the process.\n\nThis should only be done during a planned maintenance window.\n\nType CONFIRM to proceed.")
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
          if let runID = store.runApplyWithDryRun() {
            selectedRunID = runID
          }
        } label: {
          Label("Apply", systemImage: "checkmark.circle")
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

      Text("cleanup-old-execution-history.sh --days \(store.schedule.retentionDays)")
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  @ViewBuilder
  private var statusBadge: some View {
    if let lastRun = runs.first(where: { $0.status != .running }) {
      Label(
        lastRun.status == .success ? "Healthy" : "Last Run \(lastRun.status.title)",
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

        VStack(alignment: .leading, spacing: 10) {
          Text("Logs")
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
    case .stopped:
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

          Button("Done") {
            saveRemoteHostIfNeeded()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .accessibilityLabel("Done")
        }

        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 6) {
            Text("SSH Host")
              .foregroundStyle(.secondary)
            TextField("user@host.local", text: $editingRemoteHost)
              .textFieldStyle(.roundedBorder)
              .font(.callout.monospaced())
              .onSubmit { saveRemoteHostIfNeeded() }
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
            Text("Keep logs for \(schedule.retentionDays) days")
          }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

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
    }
  }

  private func saveRemoteHostIfNeeded() {
    let trimmed = editingRemoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != store.remoteHost else { return }
    store.updateRemoteHost(trimmed)
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

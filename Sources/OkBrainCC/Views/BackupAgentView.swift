import SwiftUI

struct BackupAgentView: View {
  let definition: BackupSystemDefinition

  @ObservedObject private var store = BackupAgentStore.shared
  @State private var selectedItemID: String?
  @State private var restoreOptionID = ""
  @State private var itemPendingRestore: BackupListItem?
  @State private var isConfirmingRestore = false
  @State private var isShowingSettings = false

  private var status: BackupSystemStatus? {
    store.status(for: definition.id)
  }

  private var isRunning: Bool {
    store.activeRunID(for: definition.id) != nil
  }

  private var isLoading: Bool {
    store.loadingSystemIDs.contains(definition.id)
  }

  private var selectedItem: BackupListItem? {
    backupItems.first { $0.id == selectedItemID }
  }

  private var selectedComponents: [BackupComponentStatus] {
    guard let selectedItem, let backupID = selectedItem.date else {
      return []
    }

    return store.components(forBackupDate: backupID, systemID: definition.id)
  }

  private var restoreOption: BackupRestoreOption {
    definition.restoreOptions.first { $0.id == restoreOptionID } ?? definition.restoreOptions[0]
  }

  private var backupItems: [BackupListItem] {
    let snapshotIDs = Set(store.availableRestoreDates(for: definition.id))
    let runs = store.runs(for: definition.id).filter { $0.operation == .backup }
    let runBackupIDs = Set(runs.map { Self.runIDFormatter.string(from: $0.startedAt) })

    let runItems = runs.map { run in
      let backupID = Self.runIDFormatter.string(from: run.startedAt)
      return BackupListItem(
        id: "run-\(run.id.uuidString)",
        title: backupID,
        subtitle: "\(run.status.title) · \(Self.timeFormatter.string(from: run.startedAt))",
        date: backupID,
        runID: run.id,
        status: run.status,
        canRestore: snapshotIDs.contains(backupID) && run.status != .running
      )
    }

    let snapshotItems = snapshotIDs
      .filter { !runBackupIDs.contains($0) }
      .sorted(by: >)
      .map { backupID in
        BackupListItem(
          id: "snapshot-\(backupID)",
          title: backupID,
          subtitle: "Snapshot",
          date: backupID,
          runID: nil,
          status: .success,
          canRestore: true
        )
      }

    return (runItems + snapshotItems).sorted { lhs, rhs in
      if lhs.status == .running {
        return true
      }
      if rhs.status == .running {
        return false
      }

      return lhs.title > rhs.title
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header

        HStack(alignment: .top, spacing: 18) {
          backupList
            .frame(width: 280)

          selectedBackupDetail
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      if restoreOptionID.isEmpty {
        restoreOptionID = definition.restoreOptions[0].id
      }
      store.loadBackupData(systemID: definition.id)
      ensureSelection()
      loadSelectedBackupDetails()
    }
    .onChange(of: backupItems) {
      ensureSelection()
      loadSelectedBackupDetails()
    }
    .onChange(of: selectedItemID) {
      loadSelectedBackupDetails()
    }
    .confirmationDialog(
      "Restore \(definition.title)?",
      isPresented: $isConfirmingRestore,
      titleVisibility: .visible
    ) {
      Button("Restore", role: .destructive) {
        guard let date = itemPendingRestore?.date else {
          return
        }

        _ = store.runRestore(systemID: definition.id, date: date, option: restoreOption)
      }

      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Restore \(restoreOption.title.lowercased()) on \(definition.remoteHost) from \(itemPendingRestore?.title ?? "selected backup").")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(definition.title)
            .font(.title2.weight(.semibold))

          Text("\(definition.subtitle) · \(store.schedule(for: definition.id).timeLabel)")
            .foregroundStyle(.secondary)
        }

        Spacer()

        statusBadge
      }

      HStack(spacing: 10) {
        Button {
          if let runID = store.runBackup(systemID: definition.id) {
            selectedItemID = "run-\(runID.uuidString)"
          }
        } label: {
          Label("Run Backup", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.borderedProminent)
        .disabled(isRunning)
        .accessibilityLabel("Run Backup")

        if isRunning {
          Button(role: .destructive) {
            store.stopRun(systemID: definition.id)
          } label: {
            Label("Stop", systemImage: "stop.fill")
          }
          .accessibilityLabel("Stop")
        }

        Button {
          store.openBackupDirectory(for: definition.id)
        } label: {
          Label("Open Folder", systemImage: "folder")
        }
        .accessibilityLabel("Open Folder")

        Button {
          isShowingSettings = true
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .accessibilityLabel("Settings")

        Button {
          store.loadBackupData(systemID: definition.id, force: true)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh backup status")
        .accessibilityLabel("Refresh")

        if isRunning {
          ProgressView()
            .controlSize(.small)
        }
      }

      Text(definition.backupDirectoryURL.path)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)

      if isLoading {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading backup metadata...")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .sheet(isPresented: $isShowingSettings) {
      BackupSettingsView(definition: definition, store: store)
    }
  }

  @ViewBuilder
  private var statusBadge: some View {
    if let status {
      Label(
        status.requiredComponentsAreCurrent ? "Current" : "Needs Backup",
        systemImage: status.requiredComponentsAreCurrent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
      )
      .foregroundStyle(status.requiredComponentsAreCurrent ? .green : .orange)
    } else {
      Label("Unknown", systemImage: "questionmark.circle")
        .foregroundStyle(.secondary)
    }
  }

  private var backupList: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Available Backups")
        .font(.headline)

      if isLoading && backupItems.isEmpty {
        VStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
      } else {
        List(selection: $selectedItemID) {
          ForEach(backupItems) { item in
            BackupListRow(item: item)
              .tag(item.id)
          }
        }
        .frame(minHeight: 220, idealHeight: 320, maxHeight: 420)
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  @ViewBuilder
  private var selectedBackupDetail: some View {
    if let selectedItem {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(selectedItem.title)
              .font(.title3.weight(.semibold))
            Text(selectedItem.subtitle)
              .foregroundStyle(.secondary)
          }

          Spacer()

          if selectedItem.canRestore {
            Picker("Scope", selection: $restoreOptionID) {
              ForEach(definition.restoreOptions) { option in
                Text(option.title).tag(option.id)
              }
            }
            .frame(width: 180)

            Button(role: .destructive) {
              itemPendingRestore = selectedItem
              isConfirmingRestore = true
            } label: {
              Label("Restore", systemImage: "arrow.uturn.backward.circle")
            }
            .disabled(isRunning)
            .accessibilityLabel("Restore")
          }
        }

        componentStatus(for: selectedItem)

        VStack(alignment: .leading, spacing: 10) {
          Text("Logs")
            .font(.headline)

          ScrollView {
            Text(logText(for: selectedItem))
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
      if isLoading {
        VStack(spacing: 8) {
          ProgressView()
          Text("Loading newest backup details...")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
      } else {
        ContentUnavailableView("No Backups", systemImage: "externaldrive.badge.questionmark")
          .frame(maxWidth: .infinity, minHeight: 320)
      }
    }
  }

  private func componentStatus(for selectedItem: BackupListItem) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Components")
        .font(.headline)

      if selectedComponents.isEmpty {
        Text(selectedItem.status == .running ? "Components will appear after this backup writes data." : "Loading component details...")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
          .padding(12)
          .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
      } else {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
          GridRow {
            Text("Name")
            Text("Size")
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

          ForEach(selectedComponents) { component in
            GridRow {
              Text(component.title)
              Text(component.size)
                .font(.callout.monospacedDigit())
            }

            Divider()
              .gridCellColumns(2)
          }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private func ensureSelection() {
    if let selectedItemID, backupItems.contains(where: { $0.id == selectedItemID }) {
      return
    }

    selectedItemID = backupItems.first?.id
  }

  private func loadSelectedBackupDetails() {
    guard let selectedItem, selectedItem.runID == nil, let backupID = selectedItem.date else {
      return
    }

    store.loadBackupDetails(systemID: definition.id, backupID: backupID)
  }

  private func logText(for item: BackupListItem) -> String {
    if let runID = item.runID {
      return store.logText(for: runID, systemID: definition.id)
    }

    if let date = item.date {
      return store.logText(forBackupDate: date, systemID: definition.id)
    }

    return "No logs found."
  }

  private static let runIDFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    return formatter
  }()

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()
}

private struct BackupListItem: Hashable, Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let date: String?
  let runID: BackupRun.ID?
  let status: BackupRunStatus
  let canRestore: Bool
}

private struct BackupListRow: View {
  let item: BackupListItem

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: iconName)
        .foregroundStyle(color)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .lineLimit(1)
        Text(item.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()
    }
    .padding(.vertical, 4)
  }

  private var iconName: String {
    switch item.status {
    case .running:
      "clock.arrow.circlepath"
    case .success:
      "checkmark.circle.fill"
    case .failed:
      "xmark.circle.fill"
    case .stopped:
      "stop.circle.fill"
    }
  }

  private var color: Color {
    switch item.status {
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
}

private struct BackupSettingsView: View {
  let definition: BackupSystemDefinition
  @ObservedObject var store: BackupAgentStore

  @Environment(\.dismiss) private var dismiss

  private var schedule: BackupScheduleSettings {
    store.schedule(for: definition.id)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("\(definition.title) Settings")
            .font(.title2.weight(.semibold))
          Text(definition.subtitle)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button("Done") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel("Done")
      }

      VStack(alignment: .leading, spacing: 14) {
        Toggle(
          "Run automatically",
          isOn: Binding(
            get: { schedule.isEnabled },
            set: { store.updateSchedule(systemID: definition.id, isEnabled: $0) }
          )
        )
        .toggleStyle(.checkbox)

        HStack(spacing: 12) {
          Picker(
            "Hour",
            selection: Binding(
              get: { schedule.hour },
              set: { store.updateSchedule(systemID: definition.id, hour: $0) }
            )
          ) {
            ForEach(0..<24, id: \.self) { hour in
              Text(String(format: "%02d", hour)).tag(hour)
            }
          }
          .frame(width: 130)

          Picker(
            "Minute",
            selection: Binding(
              get: { schedule.minute },
              set: { store.updateSchedule(systemID: definition.id, minute: $0) }
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
            get: { schedule.retentionCount },
            set: { store.updateSchedule(systemID: definition.id, retentionCount: $0) }
          ),
          in: 1...365
        ) {
          Text("Keep \(schedule.retentionCount) backups")
        }
      }
      .padding(16)
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
        settingsRow("In-App Time", schedule.timeLabel)
        settingsRow("Cron", schedule.cronExpression)
        settingsRow("Backups to Keep", "\(schedule.retentionCount)")
        settingsRow("Original Schedule", definition.scheduleLabel)
        settingsRow("Remote Host", definition.remoteHost)
        settingsRow("Backup Script", definition.backupScriptName)
        settingsRow("Restore Script", definition.restoreScriptName)
        settingsRow("Backup Directory", definition.backupDirectoryURL.path)
      }
      .padding(16)
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

      Spacer()
    }
    .padding(24)
    .frame(width: 620, height: 460, alignment: .topLeading)
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

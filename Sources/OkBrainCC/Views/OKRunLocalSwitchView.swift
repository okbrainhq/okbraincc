import AppKit
import SwiftUI

struct OKRunLocalSwitchView: View {
  @ObservedObject private var store = OKRunLocalSwitchStore.shared
  @State private var draft = OKRunLocalSwitchSettings.defaults
  @State private var isSetupExpanded = false
  @State private var isConfigurationExpanded = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        nodeWarning
        controlsSection
        setupSection
        configurationSection
        logsSection
        operationOutputSection
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      draft = store.settings
      store.refreshNodeStatus()
      store.refreshInstallationStatus()
      store.refreshLogs()
      syncSectionExpansion()
    }
    .onChange(of: store.isInstalled) { _, _ in
      syncSectionExpansion()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("OKRun Local Switch")
        .font(.title2.weight(.semibold))

      Text("Run OkRun's web-switch locally as a plain TCP Local Switch. No PEM files required.")
        .foregroundStyle(.secondary)
    }
  }

  private var controlsSection: some View {
    sectionCard(title: "Switch Controls", systemImage: "switch.2") {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Auto Start OKRun Local Switch", isOn: Binding {
            store.isEnabled
          } set: { isEnabled in
            if isEnabled {
              store.updateSettings(draft)
            }
            store.setEnabled(isEnabled)
          })
          .toggleStyle(.switch)
          .disabled(toggleDisabled)

          Text("Starts automatically when OkBrainCC opens. Turning it off stops the current switch.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 10) {
          statusBadges

          if store.isSwitchRunning {
            Button(role: .destructive) {
              store.stopSwitch()
            } label: {
              Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy)
          } else {
            Button {
              store.updateSettings(draft)
              store.startSwitch()
            } label: {
              Label("Start Now", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(startDisabled)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var nodeWarning: some View {
    if !store.nodeStatus.isUsable {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .font(.title3)

        VStack(alignment: .leading, spacing: 8) {
          Text(store.nodeStatus.title)
            .font(.headline)
          Text(store.nodeStatus.message)
            .foregroundStyle(.secondary)
          Text("Download and install Node.js first. Setup, switch fields, and start controls stay disabled until Node.js is ready.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
          store.installNodeJS()
        } label: {
          Label("Download & Install Node.js", systemImage: "arrow.down.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isBusy || store.isSwitchRunning)
      }
      .padding(14)
      .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private var statusBadges: some View {
    VStack(alignment: .trailing, spacing: 6) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          statusPill
          nodeBadge
          installationBadge
        }

        VStack(alignment: .trailing, spacing: 6) {
          statusPill

          HStack(spacing: 8) {
            nodeBadge
            installationBadge
          }
        }
      }

      if let detail = statusDetailText {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
          .lineLimit(3)
          .frame(maxWidth: 420, alignment: .trailing)
      }
    }
  }

  private var statusPill: some View {
    HStack(spacing: 6) {
      Label(store.status.title, systemImage: store.status.systemImage)

      if isShowingStatusSpinner {
        ProgressView()
          .controlSize(.small)
          .scaleEffect(0.78)
      }
    }
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(statusColor.opacity(0.14), in: Capsule())
    .foregroundStyle(statusColor)
  }

  private var nodeBadge: some View {
    Text(store.nodeStatus.version ?? "Node.js needed")
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(store.nodeStatus.isUsable ? .green.opacity(0.15) : .orange.opacity(0.15), in: Capsule())
      .foregroundStyle(store.nodeStatus.isUsable ? .green : .orange)
  }

  private var installationBadge: some View {
    Text(store.isInstalled ? "Switch installed" : "Switch not installed")
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(store.isInstalled ? .green.opacity(0.15) : .orange.opacity(0.15), in: Capsule())
      .foregroundStyle(store.isInstalled ? .green : .orange)
  }

  private var isShowingStatusSpinner: Bool {
    store.isBusy || store.status == .starting || store.status == .stopping
  }

  private var statusDetailText: String? {
    guard case .failed = store.status,
          let detail = store.status.detail,
          !detail.isEmpty else {
      return nil
    }

    return detail
  }

  private var setupSection: some View {
    collapsibleSectionCard(
      title: "Download & Setup",
      systemImage: "square.and.arrow.down",
      isCollapsible: setupCanCollapse,
      isExpanded: $isSetupExpanded
    ) {
      VStack(alignment: .leading, spacing: 8) {
        labeledValue("Repository", value: OKRunLocalSwitchSettings.repoURL)
        labeledValue("Component", value: OKRunLocalSwitchSettings.sourceURL)
        labeledValue("Cloned location", value: OKRunLocalSwitchSettings.installURL.path)
        labeledValue("Node.js", value: store.nodeStatus.message)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 10) {
        if store.isInstalled {
          Button {
            store.updateOKRunSwitch()
          } label: {
            Label("Update OKRun Switch", systemImage: "arrow.triangle.2.circlepath")
          }
          .buttonStyle(.borderedProminent)
          .disabled(setupDisabled)
        } else {
          Button {
            store.downloadAndSetup()
          } label: {
            Label("Download & Set Up", systemImage: "arrow.down.circle.fill")
          }
          .buttonStyle(.borderedProminent)
          .disabled(setupDisabled)
        }

        Button {
          store.updateNodeJS()
        } label: {
          Label("Update Node.js", systemImage: "arrow.up.circle")
        }
        .disabled(nodeUpdateDisabled)

        Button {
          store.refreshNodeStatus()
          store.refreshInstallationStatus()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isBusy)

        Button {
          store.openInstallDirectory()
        } label: {
          Label("Open Folder", systemImage: "folder")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var configurationSection: some View {
    collapsibleSectionCard(
      title: "Switch Configuration",
      systemImage: "slider.horizontal.3",
      isCollapsible: configurationCanCollapse,
      isExpanded: $isConfigurationExpanded
    ) {
      if !store.canConfigure {
        Text(configurationDisabledMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 12) {
        labeledField(
          "Host",
          text: $draft.host,
          prompt: "127.0.0.1"
        )

        labeledField(
          "Port",
          text: $draft.port,
          prompt: "9444"
        )

        labeledField(
          "Status port",
          text: $draft.statusPort,
          prompt: "8080"
        )
      }
      .disabled(configurationDisabled)

      HStack(spacing: 10) {
        Button {
          store.updateSettings(draft)
          syncSectionExpansion()
        } label: {
          Label("Save", systemImage: "checkmark.circle")
        }
        .disabled(configurationDisabled)

        Text("Local Switch disables TLS and only needs host, port, and status port.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var logsSection: some View {
    sectionCard(title: "Latest 100 Log Lines", systemImage: "doc.text.magnifyingglass") {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Log location")
            .font(.caption.weight(.semibold))
          Text(store.logURL.path)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer()

        Button {
          store.refreshLogs()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }

        Button {
          store.openLogDirectory()
        } label: {
          Label("Open Logs", systemImage: "folder")
        }
      }

      TailTextScrollView(
        text: store.latestLogLines,
        emptyText: "No OKRun Local Switch logs yet."
      )
      .frame(minHeight: 220, idealHeight: 300, maxHeight: 420)
      .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
  }

  @ViewBuilder
  private var operationOutputSection: some View {
    if store.isBusy || !store.lastOperationOutput.isEmpty {
      sectionCard(title: "Setup / Update Output", systemImage: "terminal") {
        TailTextScrollView(
          text: store.lastOperationOutput,
          emptyText: "No setup/update output yet."
        )
        .frame(minHeight: 120, idealHeight: 180, maxHeight: 260)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private var setupCanCollapse: Bool {
    store.isInstalled
  }

  private var configurationCanCollapse: Bool {
    store.canConfigure && draft.hasRequiredRuntimeFields
  }

  private var setupDisabled: Bool {
    store.isBusy || store.isSwitchRunning || !store.nodeStatus.isUsable
  }

  private var nodeUpdateDisabled: Bool {
    store.isBusy || store.isSwitchRunning
  }

  private var configurationDisabled: Bool {
    store.isBusy || store.isSwitchRunning || !store.canConfigure
  }

  private var startDisabled: Bool {
    store.isBusy || !store.nodeStatus.isUsable || !store.isInstalled || !draft.hasRequiredRuntimeFields
  }

  private var toggleDisabled: Bool {
    if store.isEnabled {
      return false
    }

    return store.isBusy || !store.nodeStatus.isUsable || !store.isInstalled || !draft.hasRequiredRuntimeFields
  }

  private var configurationDisabledMessage: String {
    if !store.nodeStatus.isUsable {
      return "Install Node.js first to enable OKRun Local Switch configuration."
    }

    if !store.isInstalled {
      return "Download and set up OKRun Local Switch first to enable configuration."
    }

    return "Configuration is temporarily disabled."
  }

  private var statusColor: Color {
    switch store.status {
    case .disabled, .stopped:
      .secondary
    case .starting, .stopping, .busy:
      .blue
    case .running:
      .green
    case .failed:
      .red
    }
  }

  private func syncSectionExpansion() {
    isSetupExpanded = !setupCanCollapse
    isConfigurationExpanded = !configurationCanCollapse
  }

  private func sectionCard<Content: View>(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: systemImage)
        .font(.headline)

      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
  }

  private func collapsibleSectionCard<Content: View>(
    title: String,
    systemImage: String,
    isCollapsible: Bool,
    isExpanded: Binding<Bool>,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      if isCollapsible {
        Button {
          withAnimation(.easeInOut(duration: 0.18)) {
            isExpanded.wrappedValue.toggle()
          }
        } label: {
          HStack(spacing: 8) {
            Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(width: 12)

            Label(title, systemImage: systemImage)
              .font(.headline)

            Spacer(minLength: 0)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")

        if isExpanded.wrappedValue {
          VStack(alignment: .leading, spacing: 12) {
            content()
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 10)
        }
      } else {
        Label(title, systemImage: systemImage)
          .font(.headline)

        VStack(alignment: .leading, spacing: 12) {
          content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
  }

  private func labeledField(
    _ title: String,
    text: Binding<String>,
    prompt: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption.weight(.semibold))
      TextField(prompt, text: text)
        .textFieldStyle(.roundedBorder)
    }
  }

  private func labeledValue(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption.weight(.semibold))
      Text(value)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

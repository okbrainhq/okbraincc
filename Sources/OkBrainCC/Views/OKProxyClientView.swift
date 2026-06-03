import AppKit
import SwiftUI

struct OKProxyClientView: View {
  @ObservedObject private var store = OKProxyClientStore.shared
  @State private var draft = OKProxySettings.defaults
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
      Text("OKProxy Client")
        .font(.title2.weight(.semibold))

      Text("Run the OKProxy client from a fixed local checkout.")
        .foregroundStyle(.secondary)
    }
  }

  private var controlsSection: some View {
    sectionCard(title: "Client Controls", systemImage: "switch.2") {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Auto Start OKProxy Client", isOn: Binding {
            store.isEnabled
          } set: { isEnabled in
            if isEnabled {
              store.updateSettings(draft)
            }
            store.setEnabled(isEnabled)
          })
          .toggleStyle(.switch)
          .disabled(toggleDisabled)

          Text("Starts automatically when OkBrainCC opens. Turning it off stops the current client.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 10) {
          statusBadges

          if store.isClientRunning {
            Button(role: .destructive) {
              store.stopClient()
            } label: {
              Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy)
          } else {
            Button {
              store.updateSettings(draft)
              store.startClient()
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
          Text("Download and install Node.js first. OKProxy setup, host fields, certificate paths, and start controls stay disabled until Node.js is ready.")
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
        .disabled(store.isBusy || store.isClientRunning)
      }
      .padding(14)
      .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private var statusBadges: some View {
    HStack(spacing: 8) {
      Label(store.status.title, systemImage: store.status.systemImage)
        .foregroundStyle(statusColor)

      if store.isBusy || store.status == .starting || store.status == .stopping {
        ProgressView()
          .controlSize(.small)
      }

      if let detail = store.status.detail, !detail.isEmpty {
        Text(detail)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Text(store.nodeStatus.version ?? "Node.js needed")
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(store.nodeStatus.isUsable ? .green.opacity(0.15) : .orange.opacity(0.15), in: Capsule())
        .foregroundStyle(store.nodeStatus.isUsable ? .green : .orange)

      Text(store.isInstalled ? "OKProxy installed" : "OKProxy not installed")
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(store.isInstalled ? .green.opacity(0.15) : .orange.opacity(0.15), in: Capsule())
        .foregroundStyle(store.isInstalled ? .green : .orange)
    }
  }

  private var setupSection: some View {
    collapsibleSectionCard(
      title: "Download & Setup",
      systemImage: "square.and.arrow.down",
      isCollapsible: setupCanCollapse,
      isExpanded: $isSetupExpanded
    ) {
      VStack(alignment: .leading, spacing: 8) {
        labeledValue("Repository", value: OKProxySettings.repoURL)
        labeledValue("Fixed location", value: OKProxySettings.installURL.path)
        labeledValue("Node.js", value: store.nodeStatus.message)
      }

      HStack(spacing: 10) {
        if store.isInstalled {
          Button {
            store.updateOKProxy()
          } label: {
            Label("Update OKProxy", systemImage: "arrow.triangle.2.circlepath")
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
    }
  }

  private var configurationSection: some View {
    collapsibleSectionCard(
      title: "Client Configuration",
      systemImage: "key.horizontal",
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
          "Server host",
          text: $draft.serverHost,
          prompt: "example.com:9443"
        )

        labeledField(
          "Target host",
          text: $draft.targetHost,
          prompt: "localhost:3000"
        )

        pathField("Client certificate", text: $draft.clientCertPath, prompt: "/path/to/client-cert.pem") {
          chooseFile(\.clientCertPath)
        }

        pathField("Client private key", text: $draft.clientKeyPath, prompt: "/path/to/client-key.pem") {
          chooseFile(\.clientKeyPath)
        }

        pathField("CA certificate", text: $draft.caCertPath, prompt: "/path/to/ca-cert.pem") {
          chooseFile(\.caCertPath)
        }
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

        Text("Only these three certificate/key paths are required by the OKProxy client setup: client-cert.pem, client-key.pem, and ca-cert.pem.")
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

      ScrollView {
        Text(store.latestLogLines.isEmpty ? "No OKProxy logs yet." : store.latestLogLines)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(12)
      }
      .frame(minHeight: 220, idealHeight: 300, maxHeight: 420)
      .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
  }

  @ViewBuilder
  private var operationOutputSection: some View {
    if store.isBusy || !store.lastOperationOutput.isEmpty {
      sectionCard(title: "Setup / Update Output", systemImage: "terminal") {
        ScrollView {
          Text(store.lastOperationOutput.isEmpty ? "No setup/update output yet." : store.lastOperationOutput)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(12)
        }
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
    store.isBusy || store.isClientRunning || !store.nodeStatus.isUsable
  }

  private var configurationDisabled: Bool {
    store.isBusy || store.isClientRunning || !store.canConfigure
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
      return "Install Node.js first to enable OKProxy configuration."
    }

    if !store.isInstalled {
      return "Download and set up OKProxy first to enable configuration."
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
        DisclosureGroup(isExpanded: isExpanded) {
          content()
            .padding(.top, 10)
        } label: {
          HStack {
            Label(title, systemImage: systemImage)
              .font(.headline)

            Spacer()

            Text(isExpanded.wrappedValue ? "Hide" : "Show")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }
      } else {
        Label(title, systemImage: systemImage)
          .font(.headline)

        content()
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

  private func pathField(
    _ title: String,
    text: Binding<String>,
    prompt: String,
    choose: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption.weight(.semibold))

      HStack(spacing: 8) {
        TextField(prompt, text: text)
          .textFieldStyle(.roundedBorder)

        Button {
          choose()
        } label: {
          Label("Choose", systemImage: "folder")
        }
      }
    }
  }

  private func chooseFile(_ keyPath: WritableKeyPath<OKProxySettings, String>) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false

    if panel.runModal() == .OK, let url = panel.url {
      draft[keyPath: keyPath] = url.path
    }
  }
}

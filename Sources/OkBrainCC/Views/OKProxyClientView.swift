import AppKit
import SwiftUI

struct OKProxyClientView: View {
  @ObservedObject private var store = OKProxyClientStore.shared
  @State private var draft = OKProxySettings.defaults
  @State private var isSetupExpanded = false
  @State private var isConfigurationExpanded = false
  @State private var didScrollPanelToBottom = false
  private let panelBottomID = "okproxy-panel-bottom"

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          header
          nodeWarning
          controlsSection
          setupSection
          configurationSection
          logsSection
          operationOutputSection
          Color.clear
            .frame(height: 1)
            .id(panelBottomID)
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
        scrollPanelToBottomOnInitialLoad(proxy)
      }
      .onChange(of: store.isInstalled) { _, _ in
        syncSectionExpansion()
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("OKProxy Client")
        .font(.title2.weight(.semibold))

      Text("Run the OKProxy client from a cloned local checkout.")
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
    Text(store.isInstalled ? "OKProxy installed" : "OKProxy not installed")
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
        labeledValue("Repository", value: OKProxySettings.repoURL)
        labeledValue("Cloned location", value: OKProxySettings.installURL.path)
        labeledValue("Node.js", value: store.nodeStatus.message)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

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

      TailTextScrollView(
        text: store.latestLogLines,
        emptyText: "No OKProxy logs yet."
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
    store.isBusy || store.isClientRunning || !store.nodeStatus.isUsable
  }

  private var nodeUpdateDisabled: Bool {
    store.isBusy || store.isClientRunning
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

  private func scrollPanelToBottomOnInitialLoad(_ proxy: ScrollViewProxy) {
    guard !didScrollPanelToBottom else { return }
    didScrollPanelToBottom = true

    DispatchQueue.main.async {
      proxy.scrollTo(panelBottomID, anchor: .bottom)
    }
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

private struct TailTextScrollView: NSViewRepresentable {
  let text: String
  let emptyText: String

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true

    let textView = NSTextView()
    textView.drawsBackground = false
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.font = Self.font
    textView.textColor = .labelColor
    textView.textContainerInset = NSSize(width: 12, height: 12)
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: scrollView.contentSize.width,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]

    scrollView.documentView = textView
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.scrollBoundsDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }

    let displayText = text.isEmpty ? emptyText : text
    let shouldScrollToBottom = context.coordinator.lastRenderedText.isEmpty || context.coordinator.isFollowingTail

    textView.font = Self.font
    textView.textColor = .labelColor
    textView.textContainer?.containerSize = NSSize(
      width: scrollView.contentSize.width,
      height: CGFloat.greatestFiniteMagnitude
    )

    guard context.coordinator.lastRenderedText != displayText else {
      if shouldScrollToBottom {
        DispatchQueue.main.async {
          context.coordinator.scrollToBottom(scrollView)
        }
      }
      return
    }

    textView.textStorage?.setAttributedString(
      NSAttributedString(
        string: displayText,
        attributes: [
          .font: Self.font,
          .foregroundColor: NSColor.labelColor
        ]
      )
    )
    context.coordinator.lastRenderedText = displayText

    if shouldScrollToBottom {
      DispatchQueue.main.async {
        context.coordinator.scrollToBottom(scrollView)
      }
    }
  }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    NotificationCenter.default.removeObserver(
      coordinator,
      name: NSView.boundsDidChangeNotification,
      object: nsView.contentView
    )
  }

  private static let font = NSFont.monospacedSystemFont(
    ofSize: NSFont.smallSystemFontSize,
    weight: .regular
  )

  final class Coordinator: NSObject {
    var isFollowingTail = true
    var isProgrammaticScroll = false
    var lastRenderedText = ""

    @objc func scrollBoundsDidChange(_ notification: Notification) {
      guard !isProgrammaticScroll,
            let clipView = notification.object as? NSClipView,
            let textView = clipView.documentView as? NSTextView else {
        return
      }

      updateFollowingTailState(from: textView)
    }

    func scrollToBottom(_ scrollView: NSScrollView) {
      guard let textView = scrollView.documentView as? NSTextView else { return }

      isProgrammaticScroll = true
      textView.layoutSubtreeIfNeeded()
      textView.scrollToEndOfDocument(nil)
      scrollView.reflectScrolledClipView(scrollView.contentView)
      isFollowingTail = true

      DispatchQueue.main.async { [weak self] in
        self?.isProgrammaticScroll = false
      }
    }

    private func updateFollowingTailState(from textView: NSTextView) {
      let distanceFromBottom = textView.bounds.maxY - textView.visibleRect.maxY
      isFollowingTail = distanceFromBottom <= 24
    }
  }
}

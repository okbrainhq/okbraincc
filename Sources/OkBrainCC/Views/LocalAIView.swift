import AppKit
import SwiftUI

private struct AddModelFormState: Equatable {
  var role: LocalAIModelRole = .chat
  var alias = ""
  var sourceKind: LocalAIModelSourceKind = .localFolder
  var localPath = ""
  var huggingFaceSource = "mlx-community/Qwen3-0.6B-4bit"
}

struct LocalAIView: View {
  @ObservedObject private var store = LocalAIStore.shared
  @State private var draft = LocalAISettings.defaults
  @State private var chatPrompt = "Say hello in one short sentence."
  @State private var showDownloadHints = false
  @State private var showingAddModelSheet = false
  @State private var addModelDraft = AddModelFormState()

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 18) {
        header
        modelCatalogSection
        modelHintsSection
        chatSection
        serverControls
        runtimeControls
        logsSection
        operationOutputSection
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      syncDraftFromStore()
    }
    .onChange(of: store.settings) { _, _ in
      syncDraftFromStore()
    }
    .sheet(isPresented: $showingAddModelSheet) {
      addModelSheet
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Local OpenAI API")
          .font(.title2.weight(.semibold))
        Text("Add local MLX model folders, expose them through OpenAI-compatible endpoints, and chat with a selected model.")
          .foregroundStyle(.secondary)
      }

      Spacer()
      statusPill
    }
  }

  private var modelCatalogSection: some View {
    sectionCard(title: "Models", systemImage: "shippingbox") {
      VStack(alignment: .leading, spacing: 14) {
        Text("Keep the list simple: add a model from one dialog, then pick it for chat or embeddings below.")
          .font(.callout)
          .foregroundStyle(.secondary)

        modelToolbar
        modelDownloadProgressView
        modelTable
        selectedModelControls
      }
    }
  }

  private var modelToolbar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        addModelButton
        Spacer()
        restartHint
      }

      VStack(alignment: .leading, spacing: 8) {
        addModelButton
        restartHint
      }
    }
  }

  private var addModelButton: some View {
    Button {
      openAddModelSheet()
    } label: {
      Label("Add Model", systemImage: "plus")
    }
    .buttonStyle(.borderedProminent)
    .disabled(store.isBusy)
  }

  private var saveModelsButton: some View {
    Button {
      saveDraftSettings()
    } label: {
      Label("Save Models", systemImage: "checkmark.circle")
    }
    .buttonStyle(.borderedProminent)
    .disabled(store.isBusy)
  }

  private var modelTable: some View {
    VStack(spacing: 0) {
      if draft.modelCatalog.isEmpty {
        emptyModelMessage
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(spacing: 12) {
          tableHeader("Type", width: 130)
          tableHeader("Name", minWidth: 180)
          tableHeader("Source", width: 120)
          tableHeader("Status", width: 110)
          tableHeader("Actions", width: 150)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.25))

        Divider()

        ForEach(draft.modelCatalog) { model in
          compactModelRow(model)
          Divider()
        }
      }
    }
    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(.separator.opacity(0.6), lineWidth: 1)
    )
  }

  private var emptyModelMessage: some View {
    Text("No models yet. Click Add Model to choose a local folder or download from Hugging Face.")
      .foregroundStyle(.secondary)
      .padding(12)
  }

  private func compactModelRow(_ model: LocalAIModelConfiguration) -> some View {
    HStack(spacing: 12) {
      Label(model.role.title, systemImage: model.role.systemImage)
        .frame(width: 130, alignment: .leading)

      VStack(alignment: .leading, spacing: 3) {
        Text(model.trimmedAlias)
          .font(.system(.body, design: .monospaced))
          .lineLimit(1)
        Text(model.trimmedPath.isEmpty ? "No local folder selected" : model.trimmedPath)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(model.sourceKind.shortTitle)
        .frame(width: 120, alignment: .leading)

      modelStatusLabel(model)
        .frame(width: 110, alignment: .leading)

      HStack(spacing: 8) {
        Button("Open") {
          store.openModelFolder(path: model.trimmedPath)
        }
        .disabled(model.trimmedPath.isEmpty)

        Button(role: .destructive) {
          removeModel(model.id)
          saveDraftSettings()
        } label: {
          Text("Remove")
        }
      }
      .frame(width: 150, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private func modelStatusLabel(_ model: LocalAIModelConfiguration) -> some View {
    Group {
      if model.existsOnDisk {
        Label("Ready", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      } else {
        Label("Missing", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }
    }
  }

  @ViewBuilder
  private var modelDownloadProgressView: some View {
    let progress = store.modelDownloadProgress
    if progress.isActive || progress.hasResult {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          if progress.isActive {
            ProgressView()
              .controlSize(.small)
          } else if progress.errorMessage == nil {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
          } else {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.red)
          }

          Text(progress.title.isEmpty ? "Model download" : progress.title)
            .font(.subheadline.weight(.semibold))
        }

        if !progress.detail.isEmpty {
          Text(progress.detail)
            .font(.caption)
            .foregroundStyle(progress.errorMessage == nil ? Color.secondary : Color.red)
            .fixedSize(horizontal: false, vertical: true)
        }

        if !progress.output.isEmpty {
          Text(progress.output)
            .font(.system(.caption2, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
  }

  private func simpleModelRow(model: Binding<LocalAIModelConfiguration>) -> some View {
    let id = model.wrappedValue.id
    let path = model.wrappedValue.path
    let sourceURL = model.wrappedValue.trimmedSourceURL
    let repo = repoName(from: sourceURL)

    return HStack(spacing: 8) {
      Picker("Type", selection: model.role) {
        ForEach(LocalAIModelRole.allCases) { role in
          Text(role.title).tag(role)
        }
      }
      .labelsHidden()
      .frame(width: 142)
      .help(model.wrappedValue.role.shortHint)

      TextField("qwen3:0.6b", text: model.alias)
        .textFieldStyle(.roundedBorder)
        .frame(width: 170)

      Picker("Source", selection: model.sourceKind) {
        ForEach(LocalAIModelSourceKind.allCases) { source in
          Text(source.title).tag(source)
        }
      }
      .labelsHidden()
      .frame(width: 170)

      HStack(spacing: 6) {
        TextField("/path/to/mlx/model", text: model.path)
          .textFieldStyle(.roundedBorder)
        Button {
          chooseModelFolder(id)
        } label: {
          Image(systemName: "folder")
        }
        .help("Choose local model folder")
      }
      .frame(width: 280)

      TextField("https://huggingface.co/mlx-community/...", text: model.sourceURL)
        .textFieldStyle(.roundedBorder)
        .frame(width: 250)

      HStack(spacing: 6) {
        Button {
          store.openModelFolder(path: path)
        } label: {
          Image(systemName: "folder.fill")
        }
        .help("Open local folder")
        .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Button {
          store.openURL(sourceURL)
        } label: {
          Image(systemName: "arrow.up.right.square")
        }
        .help("Open source URL")
        .disabled(sourceURL.isEmpty)

        Button {
          store.copyText(downloadCommand(for: model.wrappedValue), logMessage: "Copied model download command.")
        } label: {
          Image(systemName: "terminal")
        }
        .help("Copy download CLI command")
        .disabled(repo.isEmpty)

        Button(role: .destructive) {
          removeModel(id)
        } label: {
          Image(systemName: "trash")
        }
        .help("Remove row")
      }
      .frame(width: 150, alignment: .leading)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private var selectedModelControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Default API models")
        .font(.subheadline.weight(.semibold))

      Text("Chat and embeddings are different OpenAI API endpoints. Add an Embedding row only if you need `/v1/embeddings`; otherwise just add Chat models.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) {
          modelPicker(title: "Chat model", selection: $draft.chatAlias, models: configuredChatModels)
          modelPicker(title: "Embedding model", selection: $draft.embeddingAlias, models: configuredEmbeddingModels)
        }

        VStack(alignment: .leading, spacing: 10) {
          modelPicker(title: "Chat model", selection: $draft.chatAlias, models: configuredChatModels)
          modelPicker(title: "Embedding model", selection: $draft.embeddingAlias, models: configuredEmbeddingModels)
        }
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          validateChatButton
          validateEmbeddingButton
        }

        VStack(alignment: .leading, spacing: 8) {
          validateChatButton
          validateEmbeddingButton
        }
      }
    }
  }

  private var validateChatButton: some View {
    Button {
      saveDraftSettings()
      store.validateModel(alias: draft.trimmedChatAlias, role: .chat)
    } label: {
      Label("Validate Chat", systemImage: "text.bubble")
    }
    .disabled(store.isBusy || draft.trimmedChatAlias.isEmpty)
  }

  private var validateEmbeddingButton: some View {
    Button {
      saveDraftSettings()
      store.validateModel(alias: draft.trimmedEmbeddingAlias, role: .embedding)
    } label: {
      Label("Validate Embedding", systemImage: "point.3.filled.connected.trianglepath.dotted")
    }
    .disabled(store.isBusy || draft.trimmedEmbeddingAlias.isEmpty)
  }

  @ViewBuilder
  private var restartHint: some View {
    if store.isServerRunning {
      Text("Restart the server after changing models so API clients see the new list.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var modelHintsSection: some View {
    sectionCard(title: "Hints", systemImage: "questionmark.circle") {
      DisclosureGroup(isExpanded: $showDownloadHints) {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 8) {
            hintRow("Chat", "Use for normal LLMs and `/v1/chat/completions`.")
            hintRow("Embedding", "Only needed if you call `/v1/embeddings`.")
            hintRow("Local", "Choose an already-downloaded MLX model folder.")
            hintRow("Hugging Face", "Paste a repo like `mlx-community/Qwen3-0.6B-4bit`; the Add Model dialog downloads it and adds the row when complete.")
          }

          pathField("Default model download folder", text: $draft.modelDownloadDirectory) {
            chooseFolder(\.modelDownloadDirectory)
          }

          ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
              openDownloadFolderButton
              browseMLXButton
              browseEmbeddingsButton
              copyInstallCommandButton
            }

            VStack(alignment: .leading, spacing: 8) {
              openDownloadFolderButton
              browseMLXButton
              browseEmbeddingsButton
              copyInstallCommandButton
            }
          }

          VStack(alignment: .leading, spacing: 8) {
            ForEach(LocalAIModelDownloadLink.recommended) { link in
              downloadLinkRow(link)
            }
          }
        }
        .padding(.top, 6)
      } label: {
        Label("Where to find models and what type to choose", systemImage: "lightbulb")
          .font(.subheadline.weight(.semibold))
      }
    }
  }

  private func hintRow(_ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(title)
        .font(.caption.weight(.semibold))
        .frame(width: 92, alignment: .leading)
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var openDownloadFolderButton: some View {
    Button {
      saveDraftSettings()
      store.openModelsDirectory()
    } label: {
      Label("Open Download Folder", systemImage: "folder")
    }
  }

  private var browseMLXButton: some View {
    Button {
      store.openURL("https://huggingface.co/mlx-community")
    } label: {
      Label("Browse MLX Community", systemImage: "globe")
    }
  }

  private var browseEmbeddingsButton: some View {
    Button {
      store.openURL("https://huggingface.co/models?library=mlx&search=embedding")
    } label: {
      Label("Browse Embeddings", systemImage: "point.3.filled.connected.trianglepath.dotted")
    }
  }

  private var copyInstallCommandButton: some View {
    Button {
      store.copyText(installCommand, logMessage: "Copied Python MLX install command.")
    } label: {
      Label("Copy MLX Install Cmd", systemImage: "doc.on.doc")
    }
  }

  private func downloadLinkRow(_ link: LocalAIModelDownloadLink) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 10) {
        downloadLinkTitle(link)
        downloadLinkText(link)
        Spacer(minLength: 8)
        downloadLinkActions(link)
      }

      VStack(alignment: .leading, spacing: 8) {
        downloadLinkTitle(link)
        downloadLinkText(link)
        downloadLinkActions(link)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
  }

  private func downloadLinkTitle(_ link: LocalAIModelDownloadLink) -> some View {
    Label(link.title, systemImage: link.role.systemImage)
      .font(.subheadline.weight(.semibold))
      .frame(width: 210, alignment: .leading)
  }

  private func downloadLinkText(_ link: LocalAIModelDownloadLink) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(link.description)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(link.url)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func downloadLinkActions(_ link: LocalAIModelDownloadLink) -> some View {
    HStack(spacing: 8) {
      Button("Open") {
        store.openURL(link.url)
      }

      Button("Copy CLI") {
        store.copyText(downloadCommand(for: link), logMessage: "Copied download command for \(link.title).")
      }
      .disabled(link.repo.isEmpty)

      Button("Use in Add Model") {
        openAddModelSheet(from: link)
      }
    }
  }

  private var addModelSheet: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Label("Add Model", systemImage: "plus.square")
          .font(.title3.weight(.semibold))
        Spacer()
        Button {
          if !store.modelDownloadProgress.isActive {
            showingAddModelSheet = false
          }
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .disabled(store.modelDownloadProgress.isActive)
      }

      Text("Choose the type, give it a name, then either select an existing local MLX folder or paste a Hugging Face repo/URL to download it.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Picker("Type", selection: $addModelDraft.role) {
        ForEach(LocalAIModelRole.allCases) { role in
          Text(role.title).tag(role)
        }
      }
      .pickerStyle(.segmented)
      .disabled(store.modelDownloadProgress.isActive)

      labeledField("Name", text: $addModelDraft.alias, prompt: addModelDraft.role == .chat ? "qwen3:0.6b" : "qwen3-embedding")
        .disabled(store.modelDownloadProgress.isActive)

      VStack(alignment: .leading, spacing: 8) {
        Text("Source")
          .font(.caption.weight(.semibold))
        Picker("Source", selection: $addModelDraft.sourceKind) {
          Text("Local folder").tag(LocalAIModelSourceKind.localFolder)
          Text("Hugging Face URL").tag(LocalAIModelSourceKind.huggingFace)
        }
        .pickerStyle(.radioGroup)
        .disabled(store.modelDownloadProgress.isActive)
      }

      if addModelDraft.sourceKind == .localFolder {
        VStack(alignment: .leading, spacing: 8) {
          pathField("Local model folder", text: $addModelDraft.localPath) {
            chooseAddModelLocalFolder()
          }
          Text("Pick the folder that contains files like config.json, tokenizer files, and .safetensors. Downloads from this app usually live in \(draft.expandedModelDownloadDirectory).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(store.modelDownloadProgress.isActive)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          labeledField("Hugging Face URL or repo", text: $addModelDraft.huggingFaceSource, prompt: "Qwen/Qwen3-0.6B-MLX-4bit")
            .disabled(store.modelDownloadProgress.isActive)

          pathField("Download to", text: $addModelDraft.localPath) {
            chooseAddModelDownloadFolder()
          }
          .disabled(store.modelDownloadProgress.isActive)

          HStack(spacing: 8) {
            Text("Suggested:")
              .font(.caption.weight(.semibold))
            Text(suggestedAddModelDownloadPath)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            Button("Use Suggested") {
              addModelDraft.localPath = suggestedAddModelDownloadPath
            }
            .disabled(store.modelDownloadProgress.isActive)
          }
        }
      }

      modelDownloadProgressView

      Spacer(minLength: 0)

      HStack {
        if addModelDraft.sourceKind == .huggingFace {
          Button("Open Hugging Face") {
            let source = normalizedSourceURL(addModelDraft.huggingFaceSource)
            store.openURL(source.isEmpty ? "https://huggingface.co/mlx-community" : source)
          }
          .disabled(store.modelDownloadProgress.isActive)
        }

        Spacer()

        Button("Cancel") {
          showingAddModelSheet = false
        }
        .disabled(store.modelDownloadProgress.isActive)

        if store.modelDownloadProgress.completedPath != nil {
          Button("Done") {
            store.clearModelDownloadProgress()
            showingAddModelSheet = false
          }
          .buttonStyle(.borderedProminent)
        } else if addModelDraft.sourceKind == .localFolder {
          Button("Add") {
            addLocalModelFromSheet()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!canSubmitAddModel || store.modelDownloadProgress.isActive)
        } else {
          Button("Download & Add") {
            downloadModelFromSheet()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!canSubmitAddModel || store.modelDownloadProgress.isActive)
        }
      }
    }
    .padding(22)
    .frame(width: 620, alignment: .topLeading)
    .frame(minHeight: 520, alignment: .topLeading)
  }

  private var chatSection: some View {
    sectionCard(title: "Chat", systemImage: "message") {
      VStack(alignment: .leading, spacing: 12) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) {
            modelPicker(title: "Model", selection: $draft.chatAlias, models: configuredChatModels)
              .frame(maxWidth: 420)
            clearChatButton
          }

          VStack(alignment: .leading, spacing: 8) {
            modelPicker(title: "Model", selection: $draft.chatAlias, models: configuredChatModels)
            clearChatButton
          }
        }

        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            if store.chatMessages.isEmpty {
              Text("Pick a chat model, enter a message, and press Send.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
              ForEach(store.chatMessages) { turn in
                chatBubble(turn)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 140, maxHeight: 260)
        .padding(10)
        .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

        VStack(alignment: .leading, spacing: 8) {
          TextEditor(text: $chatPrompt)
            .font(.body)
            .frame(minHeight: 72)
            .padding(4)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
            )

          HStack {
            Text("Uses the selected Chat model alias and local folder from the table above.")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button {
              sendChat()
            } label: {
              Label("Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy || draft.trimmedChatAlias.isEmpty || chatPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
    }
  }

  private var clearChatButton: some View {
    Button(role: .destructive) {
      store.clearChat()
    } label: {
      Label("Clear", systemImage: "trash")
    }
    .disabled(store.chatMessages.isEmpty)
  }

  private func chatBubble(_ turn: LocalAIChatTurn) -> some View {
    let isUser = turn.role == "user"
    let isError = turn.role == "error"

    return HStack {
      if isUser { Spacer(minLength: 60) }

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 5) {
          Text(isUser ? "You" : (isError ? "Error" : "Assistant"))
            .font(.caption.weight(.bold))
          if let model = turn.model, !model.isEmpty {
            Text(model)
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(.secondary)
          }
        }
        Text(turn.content)
          .textSelection(.enabled)
      }
      .padding(10)
      .background(chatBubbleColor(turn).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
      .foregroundStyle(isError ? .red : .primary)

      if !isUser { Spacer(minLength: 60) }
    }
  }

  private func chatBubbleColor(_ turn: LocalAIChatTurn) -> Color {
    switch turn.role {
    case "user":
      .blue
    case "error":
      .red
    default:
      .green
    }
  }

  private var serverControls: some View {
    sectionCard(title: "Server Controls", systemImage: "point.3.connected.trianglepath.dotted") {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 16) {
          serverInfo
          Spacer()
          serverButtons
        }

        VStack(alignment: .leading, spacing: 12) {
          serverInfo
          serverButtons
        }
      }
    }
  }

  private var serverInfo: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle("Start on app launch", isOn: Binding {
        store.isEnabled
      } set: { enabled in
        draft.startOnLaunch = enabled
        store.updateSettings(draft)
        store.setEnabled(enabled)
      })
      .toggleStyle(.switch)
      .disabled(store.isBusy)

      labeledValue("Base URL", value: store.baseURL)
      labeledValue("Health", value: store.settings.healthURL)
    }
  }

  private var serverButtons: some View {
    VStack(alignment: .trailing, spacing: 10) {
      statusPill

      HStack(spacing: 8) {
        Button {
          store.copyBaseURL()
        } label: {
          Label("Copy URL", systemImage: "doc.on.doc")
        }

        Button {
          saveDraftSettings()
          store.copySampleConfig()
        } label: {
          Label("Copy Config", systemImage: "curlybraces")
        }
      }

      HStack(spacing: 8) {
        Button {
          saveDraftSettings()
          store.restartServer()
        } label: {
          Label("Restart", systemImage: "arrow.clockwise")
        }
        .disabled(store.isBusy || !store.isServerRunning)

        if store.isServerRunning {
          Button(role: .destructive) {
            store.stopServer()
          } label: {
            Label("Stop", systemImage: "stop.fill")
          }
          .buttonStyle(.borderedProminent)
          .disabled(store.isBusy)
        } else {
          Button {
            saveDraftSettings()
            store.startServer()
          } label: {
            Label("Start", systemImage: "play.fill")
          }
          .buttonStyle(.borderedProminent)
          .disabled(!store.canStart || store.isBusy)
        }
      }
    }
  }

  private var runtimeControls: some View {
    sectionCard(title: "Runtime & API Settings", systemImage: "memorychip") {
      VStack(alignment: .leading, spacing: 12) {
        Picker("Runtime", selection: $draft.runtimeKind) {
          ForEach(LocalAIRuntimeKind.allCases) { kind in
            Text(kind.title).tag(kind)
          }
        }
        .frame(maxWidth: 420, alignment: .leading)

        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) {
            labeledField("Host", text: $draft.host, prompt: "127.0.0.1")
            portField
          }

          VStack(alignment: .leading, spacing: 10) {
            labeledField("Host", text: $draft.host, prompt: "127.0.0.1")
            portField
          }
        }

        labeledField("Python executable", text: $draft.pythonExecutable, prompt: "/usr/bin/python3")

        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) {
            idleUnloadField
            Toggle("Allow no-auth on loopback", isOn: $draft.allowNoAuthOnLoopback)
              .toggleStyle(.switch)
          }

          VStack(alignment: .leading, spacing: 10) {
            idleUnloadField
            Toggle("Allow no-auth on loopback", isOn: $draft.allowNoAuthOnLoopback)
              .toggleStyle(.switch)
          }
        }

        labeledField("API key", text: $draft.apiKey, prompt: "Required for non-loopback or auth mode")

        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            testChatButton
            testEmbeddingButton
            unloadAllButton
          }

          VStack(alignment: .leading, spacing: 8) {
            testChatButton
            testEmbeddingButton
            unloadAllButton
          }
        }
      }
    }
  }

  private var portField: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Port")
        .font(.caption.weight(.semibold))
      TextField("Port", value: $draft.port, format: .number)
        .textFieldStyle(.roundedBorder)
        .frame(width: 160)
    }
  }

  private var idleUnloadField: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Idle unload seconds")
        .font(.caption.weight(.semibold))
      TextField("Idle unload seconds", value: $draft.idleUnloadSeconds, format: .number)
        .textFieldStyle(.roundedBorder)
        .frame(width: 220)
    }
  }

  private var testChatButton: some View {
    Button {
      saveDraftSettings()
      store.testChat()
    } label: {
      Label("Test Chat", systemImage: "message.fill")
    }
    .disabled(store.isBusy || draft.trimmedChatAlias.isEmpty)
  }

  private var testEmbeddingButton: some View {
    Button {
      saveDraftSettings()
      store.testEmbedding()
    } label: {
      Label("Test Embedding", systemImage: "number")
    }
    .disabled(store.isBusy || draft.trimmedEmbeddingAlias.isEmpty)
  }

  private var unloadAllButton: some View {
    Button(role: .destructive) {
      store.unloadAll()
    } label: {
      Label("Unload All", systemImage: "eject")
    }
    .disabled(store.isBusy)
  }

  private var logsSection: some View {
    sectionCard(title: "Logs", systemImage: "doc.text.magnifyingglass") {
      Text(store.latestLogLines.isEmpty ? "No logs yet." : store.latestLogLines)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(10)
        .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  @ViewBuilder
  private var operationOutputSection: some View {
    if !store.lastOperationOutput.isEmpty {
      sectionCard(title: "Validation / Test Output", systemImage: "terminal") {
        Text(store.lastOperationOutput)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
          .padding(10)
          .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private var statusPill: some View {
    HStack(spacing: 6) {
      Label(store.status.title, systemImage: store.status.systemImage)
      if store.isBusy || store.status == .starting || store.status == .stopping {
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

  private var statusColor: Color {
    switch store.status {
    case .running:
      .green
    case .failed:
      .red
    case .starting, .stopping, .busy:
      .orange
    case .disabled, .stopped:
      .secondary
    }
  }

  private var installCommand: String {
    ".build/debug/OkBrainCC local-ai install-python-mlx --venv .build/local-ai-venv"
  }

  private var configuredChatModels: [LocalAIModelConfiguration] {
    draft.modelCatalog.filter { $0.role == .chat && !$0.trimmedAlias.isEmpty }
  }

  private var configuredEmbeddingModels: [LocalAIModelConfiguration] {
    draft.modelCatalog.filter { $0.role == .embedding && !$0.trimmedAlias.isEmpty }
  }

  private var canSubmitAddModel: Bool {
    let hasName = !addModelDraft.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    switch addModelDraft.sourceKind {
    case .localFolder:
      return hasName && !addModelDraft.localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .huggingFace:
      return hasName && !repoName(from: addModelDraft.huggingFaceSource).isEmpty
    }
  }

  private var suggestedAddModelDownloadPath: String {
    suggestedModelPath(folderName: suggestedAddModelFolderName)
  }

  private var suggestedAddModelFolderName: String {
    let repo = repoName(from: addModelDraft.huggingFaceSource)
    if let last = repo.split(separator: "/").last, !last.isEmpty {
      return safeFolderName(String(last))
    }
    return safeFolderName(addModelDraft.alias.isEmpty ? "local-model" : addModelDraft.alias)
  }

  private func syncDraftFromStore() {
    draft = store.settings
    syncSelectedAliases()
  }

  private func syncSelectedAliases() {
    if !configuredChatModels.isEmpty,
       !configuredChatModels.contains(where: { $0.trimmedAlias == draft.trimmedChatAlias }) {
      draft.chatAlias = configuredChatModels.first?.trimmedAlias ?? ""
    }

    if !configuredEmbeddingModels.isEmpty,
       !configuredEmbeddingModels.contains(where: { $0.trimmedAlias == draft.trimmedEmbeddingAlias }) {
      draft.embeddingAlias = configuredEmbeddingModels.first?.trimmedAlias ?? ""
    }
  }

  private func saveDraftSettings() {
    syncSelectedAliases()
    store.updateSettings(draft)
    draft = store.settings
  }

  private func openAddModelSheet() {
    if !store.modelDownloadProgress.isActive {
      store.clearModelDownloadProgress()
    }
    let number = draft.modelCatalog.count + 1
    addModelDraft = AddModelFormState(
      role: .chat,
      alias: uniqueAlias("local-model-\(number)"),
      sourceKind: .localFolder,
      localPath: "",
      huggingFaceSource: "mlx-community/Qwen3-0.6B-4bit"
    )
    showingAddModelSheet = true
  }

  private func openAddModelSheet(from link: LocalAIModelDownloadLink) {
    if !store.modelDownloadProgress.isActive {
      store.clearModelDownloadProgress()
    }
    addModelDraft = AddModelFormState(
      role: link.role,
      alias: uniqueAlias(link.suggestedAlias),
      sourceKind: link.repo.isEmpty ? .localFolder : .huggingFace,
      localPath: link.repo.isEmpty ? "" : suggestedModelPath(folderName: link.suggestedFolderName),
      huggingFaceSource: link.repo.isEmpty ? link.url : link.repo
    )
    showingAddModelSheet = true
  }

  private func addLocalModelFromSheet() {
    let alias = addModelDraft.alias.trimmingCharacters(in: .whitespacesAndNewlines)
    let path = addModelDraft.localPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !alias.isEmpty, !path.isEmpty else { return }

    saveDraftSettings()
    store.addModel(LocalAIModelConfiguration(
      alias: uniqueAlias(alias),
      role: addModelDraft.role,
      sourceKind: .localFolder,
      path: path,
      sourceURL: "",
      notes: "Added from local folder."
    ))
    syncDraftFromStore()
    showingAddModelSheet = false
  }

  private func downloadModelFromSheet() {
    let alias = addModelDraft.alias.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = addModelDraft.huggingFaceSource.trimmingCharacters(in: .whitespacesAndNewlines)
    let destination = addModelDraft.localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? suggestedAddModelDownloadPath : addModelDraft.localPath
    guard !alias.isEmpty, !source.isEmpty else { return }

    saveDraftSettings()
    store.downloadAndAddModel(
      alias: uniqueAlias(alias),
      role: addModelDraft.role,
      source: source,
      localDir: destination
    )
  }

  private func addBlankModel() {
    let number = draft.modelCatalog.count + 1
    let alias = uniqueAlias("local-model-\(number)")
    let model = LocalAIModelConfiguration(
      alias: alias,
      role: .chat,
      sourceKind: .localFolder,
      path: "",
      sourceURL: "",
      notes: ""
    )
    draft.modelCatalog.append(model)
    draft.chatAlias = model.alias
  }

  private func addModel(from link: LocalAIModelDownloadLink) {
    let path = suggestedModelPath(folderName: link.suggestedFolderName)
    let alias = uniqueAlias(link.suggestedAlias)

    let model = LocalAIModelConfiguration(
      alias: alias,
      role: link.role,
      sourceKind: .huggingFace,
      path: path,
      sourceURL: link.url,
      notes: link.description
    )
    draft.modelCatalog.append(model)

    switch link.role {
    case .chat:
      draft.chatAlias = model.alias
    case .embedding:
      draft.embeddingAlias = model.alias
    }
  }

  private func uniqueAlias(_ proposed: String) -> String {
    let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty ? "local-model" : trimmed
    guard draft.modelCatalog.contains(where: { $0.trimmedAlias == base }) else { return base }

    var index = 2
    while draft.modelCatalog.contains(where: { $0.trimmedAlias == "\(base)-\(index)" }) {
      index += 1
    }
    return "\(base)-\(index)"
  }

  private func removeModel(_ id: UUID) {
    let removed = draft.modelCatalog.first(where: { $0.id == id })
    draft.modelCatalog.removeAll { $0.id == id }

    if removed?.role == .chat,
       !configuredChatModels.contains(where: { $0.trimmedAlias == draft.trimmedChatAlias }) {
      draft.chatAlias = configuredChatModels.first?.trimmedAlias ?? ""
      draft.chatModelPath = configuredChatModels.first?.trimmedPath ?? ""
    }

    if removed?.role == .embedding,
       !configuredEmbeddingModels.contains(where: { $0.trimmedAlias == draft.trimmedEmbeddingAlias }) {
      draft.embeddingAlias = configuredEmbeddingModels.first?.trimmedAlias ?? ""
      draft.embeddingModelPath = configuredEmbeddingModels.first?.trimmedPath ?? ""
    }
  }

  private func sendChat() {
    let prompt = chatPrompt
    saveDraftSettings()
    chatPrompt = ""
    store.sendChat(modelAlias: draft.trimmedChatAlias, prompt: prompt)
  }

  private func chooseFolder(_ keyPath: WritableKeyPath<LocalAISettings, String>) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"

    if panel.runModal() == .OK, let url = panel.url {
      draft[keyPath: keyPath] = url.path
    }
  }

  private func chooseModelFolder(_ id: UUID) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"

    if panel.runModal() == .OK, let url = panel.url,
       let index = draft.modelCatalog.firstIndex(where: { $0.id == id }) {
      draft.modelCatalog[index].path = url.path
      draft.modelCatalog[index].sourceKind = .localFolder
    }
  }

  private func chooseAddModelLocalFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose Model Folder"

    if panel.runModal() == .OK, let url = panel.url {
      addModelDraft.localPath = url.path
    }
  }

  private func chooseAddModelDownloadFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose Download Folder"

    if panel.runModal() == .OK, let url = panel.url {
      addModelDraft.localPath = url.path
    }
  }

  private func suggestedModelPath(folderName: String) -> String {
    let root = draft.trimmedModelDownloadDirectory.isEmpty ? LocalAISettings.defaults.modelDownloadDirectory : draft.trimmedModelDownloadDirectory
    return NSString(string: root).appendingPathComponent(folderName)
  }

  private func suggestedFolderName(for model: LocalAIModelConfiguration) -> String {
    let alias = model.trimmedAlias.isEmpty ? "local-model" : model.trimmedAlias
    return safeFolderName(alias)
  }

  private func safeFolderName(_ value: String) -> String {
    let safe = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: " ", with: "-")
    return safe.isEmpty ? "local-model" : safe
  }

  private func downloadCommand(for link: LocalAIModelDownloadLink) -> String {
    downloadCommand(repo: link.repo, localDir: suggestedModelPath(folderName: link.suggestedFolderName))
  }

  private func downloadCommand(for model: LocalAIModelConfiguration) -> String {
    let repo = repoName(from: model.trimmedSourceURL)
    let localDir = model.trimmedPath.isEmpty ? suggestedModelPath(folderName: suggestedFolderName(for: model)) : model.trimmedPath
    return downloadCommand(repo: repo, localDir: localDir)
  }

  private func downloadCommand(repo: String, localDir: String) -> String {
    let python = draft.trimmedPythonExecutable.isEmpty ? "/usr/bin/python3" : draft.trimmedPythonExecutable
    return """
    .build/debug/OkBrainCC local-ai download-tiny-model \\
      --python \(shellEscape(python)) \\
      --repo \(shellEscape(repo)) \\
      --local-dir \(shellEscape(localDir))
    """
  }

  private func repoName(from source: String) -> String {
    var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return "" }

    if value.hasPrefix("https://huggingface.co/") {
      value.removeFirst("https://huggingface.co/".count)
    } else if value.hasPrefix("http://huggingface.co/") {
      value.removeFirst("http://huggingface.co/".count)
    }

    value = value.split(separator: "?").first.map(String.init) ?? value
    let parts = value.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return "" }
    return "\(parts[0])/\(parts[1])"
  }

  private func normalizedSourceURL(_ source: String) -> String {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
      return trimmed
    }
    let repo = repoName(from: trimmed)
    return repo.isEmpty ? trimmed : "https://huggingface.co/\(repo)"
  }

  private func shellEscape(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private func modelPicker(title: String, selection: Binding<String>, models: [LocalAIModelConfiguration]) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption.weight(.semibold))
      Picker(title, selection: selection) {
        if models.isEmpty {
          Text("No configured models").tag("")
        } else {
          ForEach(models) { model in
            Text(model.trimmedAlias).tag(model.trimmedAlias)
          }
        }
      }
      .labelsHidden()
      .frame(maxWidth: 360, alignment: .leading)
    }
  }

  private func sectionCard<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: systemImage)
        .font(.headline)
      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
  }

  @ViewBuilder
  private func tableHeader(_ title: String, width: CGFloat? = nil, minWidth: CGFloat? = nil) -> some View {
    let text = Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)

    if let width {
      text.frame(width: width, alignment: .leading)
    } else {
      text.frame(minWidth: minWidth ?? 0, maxWidth: .infinity, alignment: .leading)
    }
  }

  private func labeledField(_ title: String, text: Binding<String>, prompt: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption.weight(.semibold))
      TextField(prompt, text: text)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 620)
    }
  }

  private func pathField(_ title: String, text: Binding<String>, choose: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption.weight(.semibold))
      HStack(spacing: 8) {
        TextField("/path/to/model", text: text)
          .textFieldStyle(.roundedBorder)
        Button {
          choose()
        } label: {
          Label("Choose", systemImage: "folder")
        }
      }
      .frame(maxWidth: 720)
    }
  }

  private func labeledValue(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption.weight(.semibold))
      Text(value)
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .foregroundStyle(.secondary)
    }
  }
}

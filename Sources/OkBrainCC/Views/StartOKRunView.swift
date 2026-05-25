import Foundation
import SwiftUI

struct StartOKRunView: View {
  @AppStorage(OKRunLauncher.appPathKey) private var appPath = OKRunLauncher.defaultAppURL.path
  @AppStorage(OKRunLauncher.autorunEnabledKey) private var isAutorunEnabled = OKRunLauncher.defaultAutorunEnabled

  @State private var launchStatus: LaunchStatus = .idle

  private var appURL: URL {
    URL(fileURLWithPath: appPath)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Toggle("Run OkrunVM when OkBrainCC starts", isOn: $isAutorunEnabled)
        .toggleStyle(.checkbox)

      VStack(alignment: .leading, spacing: 8) {
        Text("OkrunVM application")
          .font(.headline)

        HStack(spacing: 10) {
          Text(appPath)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)

          Button {
            chooseApplication()
          } label: {
            Label("Choose", systemImage: "folder")
          }
          .help("Choose the OkrunVM application")

          Button {
            appPath = OKRunLauncher.defaultAppURL.path
            launchStatus = .idle
          } label: {
            Image(systemName: "arrow.counterclockwise")
          }
          .help("Reset to /Applications/OkrunVM.app")
        }
      }

      HStack(spacing: 12) {
        Button {
          startOKRun()
        } label: {
          Label("Start Now", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)

        statusLabel
      }
    }
    .frame(maxWidth: 640, alignment: .leading)
  }

  @ViewBuilder
  private var statusLabel: some View {
    switch launchStatus {
    case .idle:
      if !OKRunLauncher.appExists(at: appURL) {
        Label("App not found", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }
    case .launching:
      ProgressView()
        .controlSize(.small)
    case .launched:
      Label("Started", systemImage: "checkmark.circle")
        .foregroundStyle(.green)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
        .lineLimit(2)
    }
  }

  private func chooseApplication() {
    guard let selectedURL = ApplicationPicker.chooseApplication(startingAt: appURL) else {
      return
    }

    appPath = selectedURL.path
    launchStatus = .idle
  }

  private func startOKRun() {
    launchStatus = .launching
    OKRunLauncher.launch(at: appURL) { result in
      switch result {
      case .success:
        launchStatus = .launched
      case .failure(let error):
        launchStatus = .failed(error.localizedDescription)
      }
    }
  }
}

private enum LaunchStatus: Equatable {
  case idle
  case launching
  case launched
  case failed(String)
}

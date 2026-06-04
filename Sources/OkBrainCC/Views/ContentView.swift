import SwiftUI

struct ContentView: View {
  @SceneStorage("selectedAppSection") private var selectedSectionID = AppSection.startOKRun.rawValue
  @StateObject private var appState = AppState.shared

  private var selection: Binding<AppSection?> {
    Binding {
      AppSection(rawValue: selectedSectionID) ?? .startOKRun
    } set: { newSelection in
      selectedSectionID = (newSelection ?? .startOKRun).rawValue
    }
  }

  var body: some View {
    NavigationSplitView {
      SidebarView(selection: selection)
    } detail: {
      DetailView(section: selection.wrappedValue ?? .startOKRun)
    }
    .overlay(shutdownOverlay)
  }

  @ViewBuilder
  private var shutdownOverlay: some View {
    if appState.isShuttingDown {
      ZStack {
        Color.black.opacity(0.4)
          .ignoresSafeArea()

        VStack(spacing: 16) {
          ProgressView()
            .scaleEffect(1.2)
            .tint(.white)

          Text(appState.shutdownMessage)
            .font(.headline)
            .foregroundStyle(.white)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
      }
      .transition(.opacity)
    }
  }
}

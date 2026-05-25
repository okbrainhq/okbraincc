import SwiftUI

struct ContentView: View {
  @SceneStorage("selectedAppSection") private var selectedSectionID = AppSection.startOKRun.rawValue

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
  }
}

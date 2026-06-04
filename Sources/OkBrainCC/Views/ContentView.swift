import SwiftUI

struct ContentView: View {
  @State private var selectedSection: AppSection? = .startOKRun

  var body: some View {
    NavigationSplitView {
      SidebarView(selection: $selectedSection)
    } detail: {
      DetailView(section: selectedSection ?? .startOKRun)
        .id(selectedSection ?? .startOKRun)
    }
  }
}

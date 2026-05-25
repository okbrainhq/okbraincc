import SwiftUI

struct SidebarView: View {
  @Binding var selection: AppSection?

  var body: some View {
    List(selection: $selection) {
      ForEach(AppSection.allCases) { section in
        Label(section.title, systemImage: section.systemImage)
          .tag(section)
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("OkBrainCC")
    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
  }
}

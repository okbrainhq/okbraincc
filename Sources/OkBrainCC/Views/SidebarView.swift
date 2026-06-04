import SwiftUI

struct SidebarView: View {
  @Binding var selection: AppSection?

  var body: some View {
    List(selection: $selection) {
      ForEach(AppSection.allCases) { section in
        SidebarSectionRow(section: section)
          .tag(section)
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("OkBrainCC")
    .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
  }
}

private struct SidebarSectionRow: View {
  let section: AppSection

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: section.systemImage)
        .frame(width: 20, alignment: .center)

      Text(section.title)
        .lineLimit(1)
        .minimumScaleFactor(0.9)
        .truncationMode(.tail)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .help(section.title)
  }
}

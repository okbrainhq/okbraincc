import SwiftUI

struct DetailView: View {
  let section: AppSection

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Image(systemName: section.systemImage)
          .font(.title2)
          .foregroundStyle(.secondary)
          .frame(width: 30)

        Text(section.title)
          .font(.largeTitle.weight(.semibold))
      }

      Divider()

      Text(section.summary)
        .font(.title3)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer()
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

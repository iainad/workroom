import SwiftUI

/// A simple centered empty/placeholder state. (ContentUnavailableView would be ideal
/// but is macOS 14+; this keeps the deployment target at macOS 13.)
struct EmptyStateView: View {
  let systemImage: String
  let title: String
  let message: String
  var action: (label: String, run: () -> Void)?

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 40))
        .foregroundStyle(.secondary)
      Text(title).font(.title3).fontWeight(.semibold)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
      if let action {
        Button(action.label, action: action.run)
          .buttonStyle(.borderedProminent)
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

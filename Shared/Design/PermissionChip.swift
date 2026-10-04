import SwiftUI

/// The status pill of a Settings permissions row. The caller passes the label, so each app's catalog owns the words.
struct PermissionChip: View {
    let status: PermissionStatus
    let label: Text

    var body: some View {
        HStack(spacing: 4) {
            switch status {
            case .granted: Image(systemName: "checkmark").fontWeight(.bold)
            case .missing: Image(systemName: "exclamationmark.triangle.fill")
            case .notNeeded, .unconfirmed: EmptyView()
            }
            label
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(status == .granted || status == .missing ? DesignTokens.Brand.ink : DesignTokens.Brand.ink2)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(fill, in: Capsule())
        .overlay(Capsule().strokeBorder(status == .missing ? DesignTokens.Brand.line : .clear, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var fill: Color {
        switch status {
        case .granted: DesignTokens.Brand.butterSoft
        case .missing: .clear
        case .notNeeded, .unconfirmed: DesignTokens.Brand.chip
        }
    }
}

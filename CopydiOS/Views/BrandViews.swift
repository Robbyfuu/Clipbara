import SwiftUI

/// The 38 pt heavy screen title that sits in the scroll content instead of a navigation bar.
struct ScreenTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .brandFont(38, .heavy, relativeTo: .largeTitle)
            .tracking(-0.035 * 38)
            .foregroundStyle(DesignTokens.Brand.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

struct EmptyState: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(DesignTokens.Brand.ink2)
                .accessibilityHidden(true)
            Text(title)
                .brandFont(20, .bold, relativeTo: .title3)
                .foregroundStyle(DesignTokens.Brand.ink)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }
}

/// The system font at the artboard's size that still follows Dynamic Type.
private struct BrandFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    func brandFont(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default,
                   relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(BrandFont(size: size, weight: weight, design: design, style: style))
    }

    /// A borderless, transparent `List` row with the screen's 20 pt side margins.
    func brandRow(top: CGFloat = 7, bottom: CGFloat = 7) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 20, bottom: bottom, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// Card surface: `card` fill with a 1 pt `line` border.
    func brandCard(radius: CGFloat = 18) -> some View {
        background(DesignTokens.Brand.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(DesignTokens.Brand.line, lineWidth: 1))
    }

    /// The card list ground shared by History and a pinboard's detail.
    func brandList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DesignTokens.Brand.shelf)
            .environment(\.defaultMinListRowHeight, 0)
    }
}

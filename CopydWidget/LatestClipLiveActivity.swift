import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

// Shared with the app, whose DEBUG -CopydLiveActivityPreview harness renders these views without ActivityKit.

/// The newest clip on the Lock Screen and in the Dynamic Island. Tapping it copies the clip.
struct LatestClipLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LatestClipActivity.self) { context in
            LatestClipLockScreen(state: context.state)
                .activityBackgroundTint(DesignTokens.Brand.shelf)
                .activitySystemActionForegroundColor(DesignTokens.Brand.ink)
                .widgetURL(QuickRoute.copyURL(context.state.clipID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { CopydMark(size: 30).padding(.leading, 6) }
                DynamicIslandExpandedRegion(.trailing) { LatestClipAge(state: context.state).padding(.trailing, 6) }
                DynamicIslandExpandedRegion(.bottom) { LatestClipIslandDetail(state: context.state) }
            } compactLeading: {
                CopydMark(size: 20)
            } compactTrailing: {
                LatestClipCompact(state: context.state)
            } minimal: {
                CopydMark(size: 20)
            }
            .widgetURL(QuickRoute.copyURL(context.state.clipID))
            .keylineTint(DesignTokens.Brand.butter)
        }
    }
}

extension LatestClipActivity.ContentState {
    /// A link reads as its host and path, without the scheme.
    var summary: String { kind == .link ? LinkParts.split(preview).map { $0.host + $0.rest } ?? preview : preview }
}

/// Lock Screen: the wordmark, the clip in 2 lines, then `source · age`. System foreground styles over the brand tint,
/// so the Lock Screen can dim and tint them.
struct LatestClipLockScreen: View {
    let state: LatestClipActivity.ContentState

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                CopydWordmark(size: 15)
                Text(state.summary).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    .privacySensitive()
                LatestClipMeta(state: state).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            LatestClipVisual(state: state, size: 52)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

/// Expanded Dynamic Island, under the mark and the age: the clip in 2 lines and its source.
struct LatestClipIslandDetail: View {
    let state: LatestClipActivity.ContentState

    var body: some View {
        HStack(spacing: 10) {
            LatestClipVisual(state: state, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.summary).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    .privacySensitive()
                Text(state.source ?? "Copyd").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Compact trailing: a few characters of the clip, or a symbol for an image or a color.
struct LatestClipCompact: View {
    let state: LatestClipActivity.ContentState

    var body: some View {
        switch state.kind {
        case .image:
            Image(systemName: "photo").foregroundStyle(DesignTokens.Brand.butter)
                .accessibilityLabel("Image")
        case .color:
            Circle().fill(Color(hex: state.preview) ?? DesignTokens.Brand.chip).frame(width: 16, height: 16)
                .accessibilityLabel(state.preview)
        case .text, .link:
            Text(state.summary).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: 64).privacySensitive()
        }
    }
}

/// The age, kept live by the system.
struct LatestClipAge: View {
    let state: LatestClipActivity.ContentState

    var body: some View {
        Text(state.copiedAt, style: .relative)
            .font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing).lineLimit(1)
    }
}

private struct LatestClipMeta: View {
    let state: LatestClipActivity.ContentState

    var body: some View {
        Text("\(state.source ?? "Copyd") \u{00b7} \(Text(state.copiedAt, style: .relative))").lineLimit(1)
    }
}

/// An image's thumbnail or a color's swatch. Nothing for text and links.
private struct LatestClipVisual: View {
    let state: LatestClipActivity.ContentState
    let size: CGFloat

    var body: some View {
        switch state.kind {
        case .image:
            Group {
                if let data = state.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(.system(size: size * 0.4)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(DesignTokens.Brand.chip)
                }
            }
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: 10))
            .privacySensitive()
            .accessibilityHidden(true)
        case .color:
            RoundedRectangle(cornerRadius: 10).fill(Color(hex: state.preview) ?? DesignTokens.Brand.chip)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesignTokens.Brand.line, lineWidth: 1))
                .frame(width: size, height: size)
                .privacySensitive()
                .accessibilityHidden(true)
        case .text, .link:
            EmptyView()
        }
    }
}

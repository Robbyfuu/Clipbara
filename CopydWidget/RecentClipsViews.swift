import SwiftData
import SwiftUI
import UIKit

// Shared with the app, whose DEBUG -CopydWidgetPreview harness renders these views without WidgetKit.

/// What the widget shows, read through `KeyboardFeed`, so it never touches `rawData`.
enum RecentClipsState {
    case noStore, empty, error
    case clips([KeyboardClip])

    /// The newest 3 clips: medium shows all of them; small and the Lock Screen show the first.
    @MainActor static func load(_ context: ModelContext) -> RecentClipsState {
        do {
            let clips = try KeyboardFeed.items(in: context, mode: .recent, limit: 3)
            return clips.isEmpty ? .empty : .clips(clips)
        } catch {
            return .error
        }
    }

    var clips: [KeyboardClip] { if case .clips(let clips) = self { clips } else { [] } }

    var message: String {
        switch self {
        case .noStore: String(localized: "Open Copyd once")
        case .empty, .clips: String(localized: "Copy something on your Mac")
        case .error: String(localized: "Couldn't load")
        }
    }
}

extension KeyboardClip {
    /// Same rule as the app's `ClipRow`: link clips, and text clips that are one bare http(s) URL.
    var linkParts: (host: String, rest: String)? {
        switch contentType {
        case .url: LinkParts.split(preview)
        case .plainText, .richText, .html: LinkParts.bareLink(preview)
        default: nil
        }
    }

    /// One line of text for the compact layouts.
    var summary: String {
        if contentType == .image { return String(localized: "Image") }
        if let parts = linkParts { return parts.host + parts.rest }
        return preview
    }
}

/// Home Screen small: the wordmark, then the newest clip's card.
struct RecentClipsSmall: View {
    let state: RecentClipsState
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CopydWordmark(size: 15)
            if let clip = state.clips.first {
                VStack(alignment: .leading, spacing: 6) {
                    content(clip).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    RecentClipMeta(clip: clip, now: now)
                }
                .padding(10)
                .background(DesignTokens.Brand.card, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DesignTokens.Brand.line, lineWidth: 1))
                .accessibilityElement(children: .combine)
            } else {
                RecentClipsMessage(text: state.message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func content(_ clip: KeyboardClip) -> some View {
        if clip.contentType == .image {
            RecentClipThumbnail(data: clip.thumbnail)
        } else if let parts = clip.linkParts {
            VStack(alignment: .leading, spacing: 2) {
                Text(parts.host).font(.system(size: 16, weight: .bold)).lineLimit(1)
                    .foregroundStyle(DesignTokens.Brand.ink)
                if !parts.rest.isEmpty {
                    Text(parts.rest).font(.system(size: 11, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                        .foregroundStyle(DesignTokens.Brand.ink2)
                }
            }
            .privacySensitive()
        } else {
            Text(clip.preview).font(.system(size: 14)).lineLimit(4)
                .foregroundStyle(DesignTokens.Brand.ink)
                .privacySensitive()
        }
    }
}

/// Home Screen medium: the wordmark beside 3 compact rows. Rows split the full height so each stays near 44 pt.
struct RecentClipsMedium: View {
    let state: RecentClipsState
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CopydWordmark(size: 15)
            if state.clips.isEmpty {
                RecentClipsMessage(text: state.message)
            } else {
                VStack(spacing: 0) {
                    ForEach(state.clips) { clip in
                        Link(destination: QuickRoute.copyURL(clip.id)) { row(clip) }
                    }
                }
                .padding(.vertical, -2)  // the rows' 2 pt tap inset reaches the margins; cards stay aligned
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ clip: KeyboardClip) -> some View {
        HStack(spacing: 8) {
            if clip.contentType == .image {
                RecentClipThumbnail(data: clip.thumbnail).frame(width: 28, height: 28)
            }
            Text(clip.summary).font(.system(size: 13, weight: clip.linkParts == nil ? .regular : .semibold))
                .lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(DesignTokens.Brand.ink)
                .privacySensitive()
            Spacer(minLength: 4)
            Text(ClipAge.text(from: clip.copiedAt, now: now)).font(.system(size: 11))
                .foregroundStyle(DesignTokens.Brand.ink2)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(DesignTokens.Brand.card, in: .rect(cornerRadius: 10))
        // The gap between cards is inside each link, so a row's tap area is a full third of the widget.
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Lock Screen rectangular: the newest clip in 2 lines. System foreground styles only, no Brand fills,
/// so the Lock Screen can tint it.
struct RecentClipsAccessory: View {
    let state: RecentClipsState
    let now: Date

    var body: some View {
        Group {
            if let clip = state.clips.first {
                VStack(alignment: .leading, spacing: 0) {
                    Text(clip.summary).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        .privacySensitive()
                    Text("\(clip.sourceAppName ?? "Copyd") \u{00b7} \(ClipAge.text(from: clip.copiedAt, now: now))")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text(state.message).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct RecentClipMeta: View {
    let clip: KeyboardClip
    let now: Date

    var body: some View {
        Text("\(clip.sourceAppName ?? "Copyd") \u{00b7} \(ClipAge.text(from: clip.copiedAt, now: now))")
            .font(.system(size: 11)).foregroundStyle(DesignTokens.Brand.ink2).lineLimit(1)
    }
}

/// The stored thumbnail, filling its frame. Never the full image.
private struct RecentClipThumbnail: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill())
            } else {
                Image(systemName: "photo").font(.system(size: 18)).foregroundStyle(DesignTokens.Brand.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DesignTokens.Brand.chip)
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .privacySensitive()
        .accessibilityElement().accessibilityLabel("Image")
    }
}

private struct RecentClipsMessage: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(DesignTokens.Brand.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

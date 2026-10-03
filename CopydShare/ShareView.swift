import SwiftUI
import UIKit

/// What the share sheet previews. The image is a `Thumbnail` PNG, never the full decode.
enum ShareContent {
    case text(String)
    case image(UIImage?)
}

@MainActor @Observable
final class ShareModel {
    enum Phase { case loading, ready, saved, failed }

    var phase = Phase.loading
    var content: ShareContent?

    init(phase: Phase = .loading, content: ShareContent? = nil) {
        self.phase = phase
        self.content = content
    }
}

/// The Share to Copyd sheet: wordmark, preview, Save. Also compiled into the app for the DEBUG preview harness.
struct ShareView: View {
    let model: ShareModel
    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                CopydWordmark(size: 26)
                if model.phase == .loading || model.phase == .ready {
                    Button("Cancel", action: onCancel)
                        .font(.body)
                        .foregroundStyle(DesignTokens.Brand.ink)
                        .frame(minWidth: 44, minHeight: 44)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            switch model.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            case .failed:
                failure
            case .ready, .saved:
                if let content = model.content { preview(content) }
                if model.phase == .saved { saved } else { butterButton("Save", action: onSave) }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.Brand.shelf)
    }

    @ViewBuilder
    private func preview(_ content: ShareContent) -> some View {
        Group {
            switch content {
            case .text(let text):
                if let link = LinkParts.bareLink(text) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(link.host, systemImage: "link")
                            .font(.headline)
                            .foregroundStyle(DesignTokens.Brand.ink)
                        if !link.rest.isEmpty {
                            Text(link.rest)
                                .font(.subheadline)
                                .foregroundStyle(DesignTokens.Brand.ink2)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                } else {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(DesignTokens.Brand.ink)
                        .lineLimit(4)
                }
            case .image(let image):
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Shared image")
                } else {
                    Label("Image", systemImage: "photo")
                        .font(.headline)
                        .foregroundStyle(DesignTokens.Brand.ink)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Brand.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(DesignTokens.Brand.line, lineWidth: 1))
    }

    private var saved: some View {
        Label {
            Text("Saved. It syncs next time you open Copyd.")
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(DesignTokens.Brand.butterInk)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(DesignTokens.Brand.ink)
        .frame(maxWidth: .infinity, minHeight: 50)
    }

    private var failure: some View {
        VStack(spacing: 16) {
            Label("Couldn't save this", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(DesignTokens.Brand.ink)
                .frame(maxWidth: .infinity, minHeight: 80)
            butterButton("Close", action: onCancel)
        }
    }

    private func butterButton(_ title: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(DesignTokens.Brand.onButter)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(ButterButtonStyle())
    }
}

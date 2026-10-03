import SwiftUI
import UIKit

enum KeyboardState: Equatable {
    case noFullAccess, noStore, error, loaded([KeyboardClip])
}

/// State and actions the controller hands to the SwiftUI keyboard.
@MainActor @Observable
final class KeyboardModel {
    var state = KeyboardState.noStore
    var mode = KeyboardFeed.Mode.recent
    var lastSync: Date?
    var toast: String?
    var showsGlobe = false

    @ObservationIgnored var onModeChange: () -> Void = {}
    /// Pastes or copies the clip; returns a toast message when the clip was copied instead of inserted.
    @ObservationIgnored var onSelect: (KeyboardClip) -> String? = { _ in nil }
    @ObservationIgnored var onText: (String) -> Void = { _ in }
    @ObservationIgnored var onDelete: () -> Void = {}
    /// Opens Copyd's keyboard setup in the containing app (no-Full-Access state only).
    @ObservationIgnored var onOpenApp: () -> Void = {}
    @ObservationIgnored let globeButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "globe")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        config.baseForegroundColor = UIColor(DesignTokens.Brand.ink)
        config.cornerStyle = .fixed
        config.background.cornerRadius = 12
        let button = UIButton(configuration: config)
        // Same pressed state as the SwiftUI keys: `keyCapPressed` while held, `keyCap` otherwise.
        button.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor =
                UIColor(button.isHighlighted ? DesignTokens.Brand.keyCapPressed : DesignTokens.Brand.keyCap)
        }
        return button
    }()
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var deleteTask: Task<Void, Never>?

    func select(_ clip: KeyboardClip) {
        guard let message = onSelect(clip) else { return }
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { toast = nil }
        }
    }

    /// Deletes once, then repeats every 0.1 s after 0.4 s until `endDelete`.
    func beginDelete() {
        guard deleteTask == nil else { return }
        onDelete()
        deleteTask = Task {
            try? await Task.sleep(for: .seconds(0.4))
            while !Task.isCancelled {
                onDelete()
                try? await Task.sleep(for: .seconds(0.1))
            }
        }
    }

    func endDelete() {
        deleteTask?.cancel()
        deleteTask = nil
    }
}

struct KeyboardView: View {
    let model: KeyboardModel
    /// Resets to false on its own when the system cancels the touch, which `DragGesture.onEnded` misses.
    @GestureState private var deletePressed = false

    var body: some View {
        VStack(spacing: 10) {
            header
            ZStack {
                content
                if let toast = model.toast {
                    Text(toast)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignTokens.Brand.onButter)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(DesignTokens.Brand.butter, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 4)
                        .allowsHitTesting(false)
                }
            }
            bottomRow
        }
        // No fill: the system keyboard background (the controller's `UIInputView`) shows through.
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            CopydWordmark(size: 21).layoutPriority(1)
            Text(RelativeSyncTime.text(from: model.lastSync, now: Date()))
                .font(.system(size: 12)).foregroundStyle(DesignTokens.Brand.ink2)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                modePill("Recent", .recent)
                modePill("Pinned", .pinned)
            }
            .padding(.horizontal, 3)
            .background(DesignTokens.Brand.line, in: Capsule())
            .layoutPriority(1)
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
    }

    private func modePill(_ title: String, _ mode: KeyboardFeed.Mode) -> some View {
        let active = model.mode == mode
        return Button {
            guard model.mode != mode else { return }
            model.mode = mode
            model.onModeChange()
        } label: {
            Text(title)
                .font(.system(size: 14, weight: active ? .bold : .semibold))
                .foregroundStyle(active ? DesignTokens.Brand.ink : DesignTokens.Brand.ink2)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .keyCap(active ? DesignTokens.Brand.keyCap : .clear, in: Capsule())
                // 3 pt each side keeps the visible capsule at 38 pt while the tap target is 44 pt.
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .noFullAccess:
            VStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 24)).foregroundStyle(DesignTokens.Brand.ink2)
                    .accessibilityHidden(true)
                Text("Turn on Allow Full Access to see your history")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(DesignTokens.Brand.ink)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 2) {
                    Text("1. Open Settings \u{2192} Apps \u{2192} Copyd")
                    Text("2. Tap Keyboards")
                    Text("3. Turn on Allow Full Access")
                }
                .font(.system(size: 13)).foregroundStyle(DesignTokens.Brand.ink2)
                Button { model.onOpenApp() } label: {
                    Label("Open Copyd", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DesignTokens.Brand.onButter)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .keyCap(DesignTokens.Brand.butter, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noStore: message("Open Copyd once to connect your history.", symbol: "iphone")
        case .error: message("Couldn't load your history.", symbol: "exclamationmark.triangle")
        case .loaded(let clips):
            if clips.isEmpty { message("Copy something on your Mac.", symbol: "clipboard") } else { grid(clips) }
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(DesignTokens.Brand.ink2)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 15, weight: .bold)).foregroundStyle(DesignTokens.Brand.ink)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func grid(_ clips: [KeyboardClip]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(clips) { clip in
                    Button { model.select(clip) } label: { card(clip) }.buttonStyle(.plain)
                }
            }
            // Room under the last row, and for its 1 pt key shadow.
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private func card(_ clip: KeyboardClip) -> some View {
        Group {
            if clip.contentType == .image, let data = clip.thumbnail, let image = UIImage(data: data) {
                Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill())
                    .accessibilityElement().accessibilityLabel("Image")
            } else if clip.contentType == .image {
                Image(systemName: "photo").font(.system(size: 22))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(DesignTokens.Brand.ink2).accessibilityLabel("Image")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    cardBody(clip)
                    Spacer(minLength: 0)
                    Text("\(clip.sourceAppName ?? "Copyd") \u{00b7} \(ClipAge.text(from: clip.copiedAt, now: Date()))")
                        .font(.system(size: 11)).foregroundStyle(DesignTokens.Brand.ink2).lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // 8 pt, not 10: three 14 pt lines plus the meta line need 68 pt of the 84 pt card.
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .keyCap(in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func cardBody(_ clip: KeyboardClip) -> some View {
        if let parts = linkParts(clip) {
            Text(parts.host).font(.system(size: 15, weight: .bold)).lineLimit(1)
                .foregroundStyle(DesignTokens.Brand.ink)
            if !parts.rest.isEmpty {
                Text(parts.rest).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(DesignTokens.Brand.ink2)
            }
        } else if clip.contentType == .color {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: clip.preview) ?? DesignTokens.Brand.chip)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesignTokens.Brand.line, lineWidth: 1))
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text(clip.preview).font(.system(size: 13, design: .monospaced)).lineLimit(1)
                    .foregroundStyle(DesignTokens.Brand.ink)
            }
        } else if clip.preview.count <= 24, !clip.preview.contains(where: \.isNewline) {
            // Short clips such as one-time codes: large, and monospaced when only digits and spaces.
            let digits = clip.preview.allSatisfy { $0.isWholeNumber || $0 == " " }
            Text(clip.preview).font(.system(size: 20, weight: .semibold, design: digits ? .monospaced : .default))
                .lineLimit(2)
                .foregroundStyle(DesignTokens.Brand.ink)
        } else {
            Text(clip.preview).font(.system(size: 14)).lineLimit(3)
                .foregroundStyle(DesignTokens.Brand.ink)
        }
    }

    /// Same rule as the app's `ClipRow`: link clips, and text clips that are one bare http(s) URL.
    private func linkParts(_ clip: KeyboardClip) -> (host: String, rest: String)? {
        switch clip.contentType {
        case .url: LinkParts.split(clip.preview)
        case .plainText, .richText, .html: LinkParts.bareLink(clip.preview)
        default: nil
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            if model.showsGlobe {
                // The UIButton paints its own fill on top; this shape only casts the key shadow.
                GlobeButton(button: model.globeButton).frame(width: 48, height: 46)
                    .keyCap(in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Next keyboard")
            }
            Button { model.onText(" ") } label: {
                Text("space").font(.system(size: 15)).foregroundStyle(DesignTokens.Brand.ink)
            }
            .buttonStyle(KeyStyle())
            Image(systemName: "delete.left").font(.system(size: 19))
                .foregroundStyle(DesignTokens.Brand.ink)
                .frame(width: 48, height: 46)
                .keyCap(deletePressed ? DesignTokens.Brand.keyCapPressed : DesignTokens.Brand.keyCap,
                        in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).updating($deletePressed) { _, pressed, _ in pressed = true })
                .onChange(of: deletePressed) { _, pressed in pressed ? model.beginDelete() : model.endDelete() }
                .accessibilityLabel("Delete").accessibilityAddTraits(.isButton)
                .accessibilityAction { model.onDelete() }
            Button { model.onText("\n") } label: {
                Text("return").font(.system(size: 15, weight: .bold)).foregroundStyle(DesignTokens.Brand.onButter)
            }
            .buttonStyle(KeyStyle(fill: DesignTokens.Brand.butter, pressedOverlay: DesignTokens.Brand.butterInk.opacity(0.2)))
            .frame(width: 76)
        }
        .frame(height: 46)
    }
}

/// A 46 pt keyboard key: `keyCap` fill that turns `keyCapPressed` while held, or a darkening overlay for the return key.
private struct KeyStyle: ButtonStyle {
    var fill = DesignTokens.Brand.keyCap
    var pressedOverlay: Color?

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .keyCap(configuration.isPressed && pressedOverlay == nil ? DesignTokens.Brand.keyCapPressed : fill, in: shape)
            .overlay { if configuration.isPressed, let pressedOverlay { shape.fill(pressedOverlay) } }
            .contentShape(shape)
    }
}

private extension View {
    /// A native-key surface behind the view: `fill` in `shape`, with a hard 1 pt shadow below. A clear fill casts none.
    func keyCap(_ fill: Color = DesignTokens.Brand.keyCap, in shape: some Shape) -> some View {
        background { shape.fill(fill).shadow(color: DesignTokens.Brand.keyShadow, radius: 0, y: 1) }
    }
}

/// Wraps the controller's real `UIButton`, which `handleInputModeList(from:with:)` needs for its event.
private struct GlobeButton: UIViewRepresentable {
    let button: UIButton
    func makeUIView(context: Context) -> UIButton { button }
    func updateUIView(_ uiView: UIButton, context: Context) {}
}

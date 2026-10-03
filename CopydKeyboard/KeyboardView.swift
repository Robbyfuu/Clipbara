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
    @ObservationIgnored let globeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
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
        VStack(spacing: 6) {
            header
            ZStack {
                content
                if let toast = model.toast {
                    Text(toast)
                        .font(.footnote.weight(.semibold))
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
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(DesignTokens.Brand.shelf)
    }

    private var header: some View {
        HStack(spacing: 8) {
            CopydMark(size: 20)
            Text(RelativeSyncTime.text(from: model.lastSync, now: Date()))
                .font(.caption).foregroundStyle(DesignTokens.Brand.ink2)
                .lineLimit(1)
            Spacer(minLength: 8)
            Picker("Show", selection: Binding(get: { model.mode }, set: { model.mode = $0; model.onModeChange() })) {
                Text("Recent").tag(KeyboardFeed.Mode.recent)
                Text("Pinned").tag(KeyboardFeed.Mode.pinned)
            }
            .pickerStyle(.segmented).frame(width: 170)
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .noFullAccess:
            VStack(alignment: .leading, spacing: 4) {
                Text("Turn on Allow Full Access to see your history").font(.subheadline.weight(.semibold))
                Text("1. Open Settings \u{2192} General \u{2192} Keyboard \u{2192} Keyboards")
                Text("2. Tap Add New Keyboard\u{2026} \u{2192} Copyd")
                Text("3. Tap Copyd \u{2192} turn on Allow Full Access")
            }
            .font(.footnote).foregroundStyle(DesignTokens.Brand.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
        case .noStore: message("Open Copyd once to connect your history.")
        case .error: message("Couldn't load your history.")
        case .loaded(let clips):
            if clips.isEmpty { message("Copy something on your Mac.") } else { grid(clips) }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(DesignTokens.Brand.ink2)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func grid(_ clips: [KeyboardClip]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(clips) { clip in
                    Button { model.select(clip) } label: { card(clip) }.buttonStyle(.plain)
                }
            }
        }
    }

    private func card(_ clip: KeyboardClip) -> some View {
        Group {
            if clip.contentType == .image, let data = clip.thumbnail, let image = UIImage(data: data) {
                Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill())
                    .accessibilityElement().accessibilityLabel("Image")
            } else if clip.contentType == .image {
                Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(DesignTokens.Brand.ink2).accessibilityLabel("Image")
            } else {
                Text(clip.preview).font(.footnote).lineLimit(3)
                    .foregroundStyle(DesignTokens.Brand.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(8)
            }
        }
        .frame(height: 88)
        .background(DesignTokens.Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DesignTokens.Brand.line))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if model.showsGlobe {
                GlobeButton(button: model.globeButton).frame(width: 52, height: 44)
                    .background(DesignTokens.Brand.chip, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Next keyboard")
            }
            key("space") { model.onText(" ") }.frame(maxWidth: .infinity)
            Image(systemName: "delete.left").frame(width: 52, height: 44)
                .foregroundStyle(DesignTokens.Brand.ink)
                .background(DesignTokens.Brand.chip, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).updating($deletePressed) { _, pressed, _ in pressed = true })
                .onChange(of: deletePressed) { _, pressed in pressed ? model.beginDelete() : model.endDelete() }
                .accessibilityLabel("Delete").accessibilityAddTraits(.isButton)
                .accessibilityAction { model.onDelete() }
            key("return") { model.onText("\n") }.frame(width: 76)
        }
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline).foregroundStyle(DesignTokens.Brand.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(DesignTokens.Brand.chip, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// Wraps the controller's real `UIButton`, which `handleInputModeList(from:with:)` needs for its event.
private struct GlobeButton: UIViewRepresentable {
    let button: UIButton
    func makeUIView(context: Context) -> UIButton { button }
    func updateUIView(_ uiView: UIButton, context: Context) {}
}

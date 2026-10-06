import SwiftUI
import SwiftData

struct HistoryPanelView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \ClipboardItem.copiedAt, order: .reverse)
    private var items: [ClipboardItem]

    private var shelfShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 20,
            style: .continuous
        )
    }

    @ViewBuilder
    private var shelfFill: some View {
        if #available(macOS 26, *) {
            // Tint as content, not `Glass.tint(_:)`, which renders only while the app is active.
            shelfShape
                .fill(DesignTokens.Brand.glassTint)
                .glassEffect(.regular, in: shelfShape)
        } else {
            shelfShape
                .fill(DesignTokens.Brand.shelf)
        }
    }

    var body: some View {
        ZStack {
            shelfFill
                .overlay(alignment: .top) {
                    // Hairline along the top curve only.
                    shelfShape
                        .strokeBorder(DesignTokens.Brand.line, lineWidth: 1)
                        .mask(alignment: .top) { Rectangle().frame(height: 20) }
                }
                .ignoresSafeArea()

            VStack(spacing: 0) {
                NavigationBarView()

                ZStack {
                    // Cards layer
                    Group {
                        // History, and each automatic pinboard as History narrowed to its clips.
                        CardGridView()
                            .opacity(appState.selectedTab.showsHistoryGrid ? 1 : 0)
                            .allowsHitTesting(appState.selectedTab.showsHistoryGrid)

                        if case .pinboard(let id) = appState.selectedTab {
                            PinboardGridView(pinboardId: id)
                                .id(id)
                        }
                    }
                    .opacity(appState.previewItem == nil ? 1 : 0)

                    // Preview layer (replaces cards)
                    if let previewItem = appState.previewItem {
                        PreviewView(
                            item: previewItem,
                            onClose: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    appState.searchState.selectedIndex = nil
                                    appState.selectForPreview(nil)
                                }
                            },
                            onPaste: {
                                appState.clipboardMonitor.skipNextChange(picking: [previewItem.id])
                                appState.pasteService.paste(item: previewItem)
                                appState.hidePanel()
                            }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)),
                            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                        ))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: appState.selectedTab) { _, _ in
                appState.selectForPreview(nil)
            }

            MultiPasteBar()

            if let toast = appState.panelToast {
                PanelToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.16), value: appState.panelToast)
    }
}

/// Shown under the top bar while two or more cards are picked: the count, the separator and Paste.
/// It hangs over the cards' top margin because the shelf has no spare height for another row.
/// Always mounted and hidden with height and opacity, never with `if`, beside the `@Query` grids.
private struct MultiPasteBar: View {
    @Environment(AppState.self) private var appState
    @State private var separator = Separator.saved()
    @State private var customText: String = {
        if case .custom(let raw) = Separator.saved() { return raw }
        return ""
    }()

    private static let height: CGFloat = 26
    private static let presets: [Separator] = [.newline, .space, .comma, .tab]

    var body: some View {
        let items = appState.multiSelectedItems
        let isVisible = items.count >= 2
        let skipped = items.filter { MultiPaste.text(of: $0) == nil }.count

        HStack(spacing: 10) {
            Text("\(items.count) selected")
                .foregroundStyle(DesignTokens.Brand.ink)

            if skipped > 0 {
                Text("Text only — \(skipped) skipped")
                    .foregroundStyle(DesignTokens.Brand.ink2)
            }

            separatorMenu

            // In the panel itself, like the search field: a popover opens its own window and can activate Copyd.
            if case .custom = separator {
                TextField("Separator", text: $customText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .frame(width: 90, height: Self.height - 6)
                    .background(DesignTokens.Brand.chip, in: Capsule())
                    .help("Use \\n for a new line, \\t for a tab")
                    .onSubmit { appState.pasteSelection() }
                    .onChange(of: customText) { _, text in separator = .custom(text) }
            }

            Button {
                appState.pasteSelection()
            } label: {
                Text("Paste")
                    .foregroundStyle(DesignTokens.Brand.onButter)
                    .padding(.horizontal, 10)
                    .frame(height: Self.height - 6)
                    .background(DesignTokens.Brand.butter, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(skipped == items.count)
            .opacity(skipped == items.count ? 0.45 : 1)
        }
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
        .padding(.leading, 12)
        .padding(.trailing, 3)
        .frame(height: Self.height)
        .background(DesignTokens.Brand.card, in: Capsule())
        .overlay(Capsule().strokeBorder(DesignTokens.Brand.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .fixedSize()
        .frame(height: isVisible ? Self.height : 0, alignment: .top)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .animation(.easeOut(duration: 0.16), value: isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Between the top bar's controls and the cards' first line of content.
        .padding(.top, DesignTokens.Nav.height - 9)
        .onChange(of: separator) { _, new in new.save() }
    }

    private var separatorMenu: some View {
        Menu {
            ForEach(Self.presets, id: \.string) { preset in
                Button {
                    separator = preset
                } label: {
                    if preset == separator {
                        Label { title(of: preset) } icon: { Image(systemName: "checkmark") }
                    } else {
                        title(of: preset)
                    }
                }
            }
            Divider()
            Button {
                separator = .custom(customText)
            } label: {
                if case .custom = separator {
                    Label("Custom…", systemImage: "checkmark")
                } else {
                    Text("Custom…")
                }
            }
        } label: {
            HStack(spacing: 4) {
                title(of: separator)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(DesignTokens.Brand.ink2)
            .padding(.horizontal, 8)
            .frame(height: Self.height - 6)
            .background(DesignTokens.Brand.chip, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Separator")
    }

    private func title(of separator: Separator) -> Text {
        switch separator {
        case .newline: Text("New line")
        case .space: Text("Space")
        case .comma: Text("Comma")
        case .tab: Text("Tab")
        case .custom(let raw): Text(verbatim: "“\(raw)”")
        }
    }
}

private struct PanelToastView: View {
    let toast: PanelToast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 12, weight: .semibold))

            Text(toast.message)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.primary.opacity(0.86))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, DesignTokens.Nav.height + 8)
        .allowsHitTesting(false)
    }
}

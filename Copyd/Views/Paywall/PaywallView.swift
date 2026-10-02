import SwiftUI
import StoreKit

/// Drives the purchase buttons and remembers what just happened, so the window
/// can confirm a started trial or an unlock instead of closing abruptly.
@MainActor
@Observable
final class PaywallModel {
    enum Completion {
        case trialStarted
        case unlocked
    }

    private(set) var completion: Completion?
    private(set) var message: String?

    func reset() {
        completion = nil
        message = nil
    }

    func startTrial() {
        guard let product = Entitlements.shared.trialProduct else { return }
        Task {
            message = nil
            let outcome = await Entitlements.shared.purchase(product)
            handle(outcome) {
                switch Entitlements.shared.state {
                case .unlocked(.lifetime), .unlocked(.grandfathered): .unlocked
                default: .trialStarted
                }
            }
        }
    }

    func unlock() {
        guard let product = Entitlements.shared.lifetimeProduct else { return }
        Task {
            message = nil
            let outcome = await Entitlements.shared.purchase(product)
            handle(outcome) { .unlocked }
        }
    }

    func restore() {
        Task {
            message = nil
            switch await Entitlements.shared.restorePurchases() {
            case .restored:
                switch Entitlements.shared.state {
                case .unlocked(.lifetime), .unlocked(.grandfathered):
                    completion = .unlocked
                default:
                    message = String(localized: "Your purchases were restored.")
                }
            case .nothingFound:
                message = String(localized: "No unlock purchase was found for this Apple Account.")
            case .failed:
                message = String(localized: "Couldn't restore purchases. Check your connection and try again.")
            case .cancelled:
                break
            }
        }
    }

    func retryLoadingProducts() {
        Task { await Entitlements.shared.loadProducts() }
    }

    private func handle(_ outcome: Entitlements.PurchaseOutcome, completed: () -> Completion) {
        switch outcome {
        case .completed:
            completion = completed()
        case .pending:
            message = String(localized: "Your purchase is waiting for approval. Clipbara unlocks as soon as it goes through.")
        case .failed:
            message = String(localized: "The purchase couldn't be completed. Please try again.")
        case .cancelled:
            break
        }
    }
}

/// The trial and unlock screen. Before the trial starts it states the trial
/// length, what stops working when it ends, and the one-time price, as App
/// Review Guideline 3.1.1 requires for free time-based trials.
struct PaywallView: View {
    let model: PaywallModel
    let onClose: () -> Void
    /// Reports the content height so the window can follow it outside of layout.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    private let accent = Color(red: 0.145, green: 0.388, blue: 0.922) // #2563EB, matches onboarding

    private var entitlements: Entitlements { .shared }

    var body: some View {
        VStack(spacing: 0) {
            if let completion = shownCompletion {
                completionContent(completion)
            } else {
                offerContent
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 22)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
    }

    /// Also covers an unlock that arrives from elsewhere while the window is open,
    /// such as an approved Ask to Buy or a purchase on another Mac.
    private var shownCompletion: PaywallModel.Completion? {
        if let completion = model.completion { return completion }
        switch entitlements.state {
        case .unlocked(.lifetime), .unlocked(.grandfathered): return .unlocked
        default: return nil
        }
    }

    // MARK: - Offer

    private var isTrialOffer: Bool {
        entitlements.state == .trialNotStarted
    }

    private var price: String? {
        entitlements.lifetimeProduct?.displayPrice
    }

    private var offerContent: some View {
        VStack(spacing: 0) {
            appIcon

            header
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 14) {
                if isTrialOffer {
                    row(
                        symbol: "calendar",
                        title: "7 days of full access",
                        detail: Text("History, pinboards, search and paste all work. The trial is free and never charges or renews on its own.")
                    )
                }
                if entitlements.state == .trialExpired {
                    row(
                        symbol: "tray.full",
                        title: "Your history is safe",
                        detail: Text("Clipbara kept recording what you copy. Settings, including backup export, stay available.")
                    )
                } else {
                    row(
                        symbol: "lock",
                        title: "When the trial ends",
                        detail: Text("Opening your clipboard history and pasting clips from Clipbara stop until you unlock. Copying is still recorded, and Settings, including backup export, stay available.")
                    )
                }
                row(
                    symbol: "checkmark.seal",
                    title: "One-time purchase, no subscription",
                    detail: price.map { Text("Unlock Clipbara for \($0) and keep full access.") }
                        ?? Text("Unlock Clipbara with a single purchase and keep full access.")
                )
            }
            .padding(.top, 24)

            buttons
                .padding(.top, 26)

            if let message = model.message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            footer
                .padding(.top, 18)
        }
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 72, height: 72)
            .shadow(color: accent.opacity(0.28), radius: 12, y: 7)
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 7) {
            switch entitlements.state {
            case .trialNotStarted:
                title(Text("Try Clipbara free for 7 days"))
                subtitle(Text("Full access to everything. When the trial ends, keep using Clipbara with a one-time purchase."))
            case .trialActive:
                title(Text("Unlock Clipbara"))
                if let end = entitlements.trialEndDate {
                    subtitle(Text("Your free trial ends on \(end, format: .dateTime.month(.wide).day().hour().minute())."))
                }
            case .trialExpired:
                title(Text("Your free trial has ended"))
                subtitle(Text("Unlock Clipbara to open your clipboard history again. Everything you copied in the meantime has been kept."))
            case .unlocked:
                title(Text("Unlock Clipbara"))
            }
        }
    }

    private func title(_ text: Text) -> some View {
        text
            .font(.system(size: 22, weight: .bold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func subtitle(_ text: Text) -> some View {
        text
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(symbol: String, title: LocalizedStringKey, detail: Text) -> some View {
        HStack(alignment: .top, spacing: 13) {
            RoundedRectangle(cornerRadius: 8)
                .fill(accent.opacity(colorScheme == .dark ? 0.18 : 0.09))
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(accent)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                detail
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 10) {
            if isTrialOffer {
                primaryButton(Text("Start 7-Day Free Trial"), action: model.startTrial)
                    // The price must be on screen before anyone starts the trial.
                    .disabled(entitlements.trialProduct == nil || price == nil)
                if let price {
                    Button(action: model.unlock) {
                        Text("Unlock for \(price)")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(entitlements.isBusy)
                }
            } else {
                primaryButton(
                    price.map { Text("Unlock for \($0)") } ?? Text("Unlock Clipbara"),
                    action: model.unlock
                )
                .disabled(price == nil)
            }

            if price == nil, !entitlements.isLoadingProducts {
                HStack(spacing: 6) {
                    Text("Couldn't connect to the App Store.")
                        .foregroundStyle(.secondary)
                    Button("Try Again", action: model.retryLoadingProducts)
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                }
                .font(.system(size: 12))
            }
        }
    }

    private func primaryButton(_ label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                label
                    .opacity(isWorking ? 0 : 1)
                ProgressView()
                    .controlSize(.small)
                    .environment(\.colorScheme, .dark)
                    .opacity(isWorking ? 1 : 0)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.231, green: 0.443, blue: 0.953), accent],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .shadow(color: accent.opacity(0.28), radius: 7, y: 3)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(entitlements.isBusy)
    }

    private var isWorking: Bool {
        entitlements.isBusy || (price == nil && entitlements.isLoadingProducts)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Restore Purchases", action: model.restore)
                .disabled(entitlements.isBusy)
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
            Button("Not Now", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
    }

    // MARK: - Completion

    private func completionContent(_ completion: PaywallModel.Completion) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.353, green: 0.576, blue: 0.980), accent],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 60, height: 60)
                    .shadow(color: accent.opacity(0.35), radius: 12, y: 6)
                Image(systemName: "checkmark")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 8)

            VStack(spacing: 7) {
                switch completion {
                case .trialStarted:
                    title(Text("Your free trial has started"))
                    if let end = entitlements.trialEndDate {
                        subtitle(Text("It ends on \(end, format: .dateTime.month(.wide).day().hour().minute()). You can unlock Clipbara anytime from the menu bar."))
                    }
                case .unlocked:
                    title(Text("Clipbara is unlocked"))
                    subtitle(Text("Thank you for supporting Clipbara."))
                }
            }
            .padding(.top, 18)

            primaryButton(Text("Done"), action: onClose)
                .padding(.top, 26)
        }
    }
}

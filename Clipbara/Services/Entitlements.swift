#if APPSTORE
import Foundation
import StoreKit
import os.log

/// StoreKit side of the free trial and the one-time unlock (Mac App Store build only).
///
/// Every decision is delegated to `AccessPolicy`. This type only gathers its
/// inputs: the app transaction (who is grandfathered) and the current
/// entitlements (the $0 trial and the lifetime unlock). Any StoreKit error leaves
/// the input unknown, which `AccessPolicy` treats as unlocked.
@MainActor
@Observable
final class Entitlements {
    static let shared = Entitlements()

    enum ProductID {
        /// Non-consumable at $0, named "7-day Trial" per App Review Guideline 3.1.1.
        /// Its original purchase date is the trial start, tied to the Apple Account.
        static let trial = "com.minsang.Clipbara.trial7day"
        static let lifetime = "com.minsang.Clipbara.lifetime"
        static let all = [trial, lifetime]
    }

    enum PurchaseOutcome {
        case completed
        case cancelled
        case pending
        case failed
    }

    enum RestoreOutcome {
        case restored
        case nothingFound
        case cancelled
        case failed
    }

    /// Unlocked until the first check completes, so a slow launch never locks anyone out.
    private(set) var state: AccessState = .unlocked(.unverified)
    private(set) var trialEndDate: Date?
    private(set) var trialProduct: Product?
    private(set) var lifetimeProduct: Product?
    private(set) var isLoadingProducts = false
    private(set) var isBusy = false

    @ObservationIgnored private var isGrandfathered: Bool?
    @ObservationIgnored private var hasLifetime: Bool?
    @ObservationIgnored private var trialStart: Date?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    private static let logger = Logger(subsystem: "com.minsang.PasteClip", category: "Entitlements")

    private init() {}

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await Self.finishIfVerified(update)
                await self?.refresh()
            }
        }

        Task {
            for await result in Transaction.unfinished {
                await Self.finishIfVerified(result)
            }
            await refresh()
            await loadProducts()
        }
    }

    /// Re-reads the app transaction (until it is known) and the current entitlements.
    func refresh() async {
        if isGrandfathered == nil {
            isGrandfathered = await Self.loadGrandfathered()
        }
        let purchases = await Self.loadPurchases()
        hasLifetime = purchases.hasLifetime
        trialStart = purchases.trialStart
        reevaluate()
    }

    /// Recomputes the state against the current time without touching StoreKit.
    func reevaluate(now: Date = .now) {
        let newState = AccessPolicy.state(
            isGrandfathered: isGrandfathered,
            hasLifetime: hasLifetime,
            trialStart: trialStart,
            now: now
        )
        if newState != state {
            Self.logger.info("Access state: \(String(describing: newState), privacy: .public)")
            state = newState
        }
        let newEnd = trialStart.map(AccessPolicy.trialEnd(from:))
        if newEnd != trialEndDate { trialEndDate = newEnd }
    }

    /// Checked right before the history panel opens, so a trial that ran out
    /// while the app kept running locks on the next open. Uses what is already
    /// known and refreshes in the background for the next time.
    func checkHistoryAccess() -> Bool {
        reevaluate()
        Task { await refresh() }
        return state.allowsHistoryAccess
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let products = try await Product.products(for: ProductID.all)
            trialProduct = products.first { $0.id == ProductID.trial }
            lifetimeProduct = products.first { $0.id == ProductID.lifetime }
            if trialProduct == nil || lifetimeProduct == nil {
                Self.logger.error("Missing products: got \(products.map(\.id), privacy: .public)")
            }
        } catch {
            Self.logger.error("Loading products failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func purchase(_ product: Product) async -> PurchaseOutcome {
        isBusy = true
        defer { isBusy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refresh()
                    return .completed
                case .unverified(_, let error):
                    Self.logger.error("Unverified purchase of \(product.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    await refresh()
                    return .failed
                }
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed
            }
        } catch {
            Self.logger.error("Purchase of \(product.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    func restorePurchases() async -> RestoreOutcome {
        isBusy = true
        defer { isBusy = false }
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch {
            Self.logger.error("Restore failed: \(error.localizedDescription, privacy: .public)")
            await refresh()
            return .failed
        }
        await refresh()
        if trialProduct == nil || lifetimeProduct == nil { await loadProducts() }
        switch state {
        case .unlocked(.unverified): return .failed
        case .unlocked, .trialActive: return .restored
        case .trialNotStarted, .trialExpired: return .nothingFound
        }
    }

    // MARK: - StoreKit reads

    private static func finishIfVerified(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            await transaction.finish()
        case .unverified(let transaction, let error):
            logger.error("Unverified transaction for \(transaction.productID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `nil` when the app transaction is unavailable or unverified.
    private static func loadGrandfathered() async -> Bool? {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: DebugOverride.originalAppVersionKey),
           !override.isEmpty {
            logger.debug("Debug override: originalAppVersion = \(override, privacy: .public)")
            return AccessPolicy.isGrandfathered(originalAppVersion: override)
        }
        #endif
        do {
            switch try await AppTransaction.shared {
            case .verified(let transaction):
                let version = transaction.originalAppVersion
                var platform = AccessPolicy.OriginalPlatform.unknown
                if #available(macOS 15.4, *) {
                    platform = transaction.originalPlatform == .macOS ? .mac : .other
                }
                let grandfathered = AccessPolicy.isGrandfathered(originalAppVersion: version, originalPlatform: platform)
                if grandfathered == nil {
                    logger.error("Unrecognized originalAppVersion \(version, privacy: .public)")
                }
                return grandfathered
            case .unverified(_, let error):
                logger.error("App transaction unverified: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        } catch {
            logger.error("App transaction unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// `hasLifetime` is `nil` when an unverified transaction for one of our
    /// products turns up, since that could be the purchase we can't confirm.
    private static func loadPurchases() async -> (hasLifetime: Bool?, trialStart: Date?) {
        var hasLifetime = false
        var trialStart: Date?
        var sawUnverified = false

        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                guard transaction.revocationDate == nil else { continue }
                switch transaction.productID {
                case ProductID.lifetime:
                    hasLifetime = true
                case ProductID.trial:
                    // Restores and re-downloads keep the original purchase date,
                    // so reinstalling never resets the trial.
                    let start = transaction.originalPurchaseDate
                    trialStart = min(trialStart ?? start, start)
                default:
                    break
                }
            case .unverified(let transaction, let error):
                guard ProductID.all.contains(transaction.productID) else { continue }
                logger.error("Unverified entitlement \(transaction.productID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                sawUnverified = true
            }
        }

        #if DEBUG
        let shiftDays = UserDefaults.standard.double(forKey: DebugOverride.trialShiftDaysKey)
        if shiftDays != 0, let start = trialStart {
            trialStart = start.addingTimeInterval(-shiftDays * 24 * 60 * 60)
            logger.debug("Debug override: trial start shifted back \(shiftDays) days")
        }
        #endif

        if hasLifetime { return (true, trialStart) }
        if sawUnverified { return (nil, nil) }
        return (false, trialStart)
    }
}

#if DEBUG
/// Debug-only switches for testing the trial locally. Release builds never
/// compile this, so shipped builds cannot read either key.
///
/// Pass them as launch arguments in the ClipbaraMAS scheme, e.g.
/// `-ClipbaraDebugOriginalAppVersion 1.4` (sandbox and Xcode report "1.0",
/// which counts as grandfathered) and `-ClipbaraDebugTrialShiftDays 8`
/// (pretends the trial started 8 days earlier than StoreKit says).
enum DebugOverride {
    static let originalAppVersionKey = "ClipbaraDebugOriginalAppVersion"
    static let trialShiftDaysKey = "ClipbaraDebugTrialShiftDays"
}
#endif
#endif

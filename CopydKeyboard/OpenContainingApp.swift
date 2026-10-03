// UNOFFICIAL TECHNIQUE. A keyboard extension has no public API to open its containing app. This walks the
// responder chain to the host process's UIApplication and calls open(_:options:completionHandler:) through the
// Objective-C runtime, the technique Gboard and SwiftKey use. It may stop working in a future iOS, and App Review
// may reject it, so review it before any App Store submission. Everything that depends on it lives in this file.

import UIKit

enum OpenContainingApp {
    /// Opens `url` through the `UIApplication` in `responder`'s chain. Does nothing when there is none or it no
    /// longer answers the selector; the keyboard's written steps stay on screen as the fallback.
    @MainActor
    static func open(_ url: URL, from responder: UIResponder) {
        var next: UIResponder? = responder
        while let current = next, !(current is UIApplication) { next = current.next }
        // `UIApplication.open` is unavailable to extensions at compile time, so it is looked up at run time.
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard let application = next, application.responds(to: selector),
              let implementation = application.method(for: selector) else { return }
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
        unsafeBitCast(implementation, to: OpenURL.self)(application, selector, url as NSURL, NSDictionary(), nil)
    }
}

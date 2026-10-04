import CoreGraphics
import XCTest

/// One test per combination of `AutoPastePolicy.decide`'s four inputs.
final class AutoPastePolicyTests: XCTestCase {
    private func decide(enabled: Bool, access: Bool, active: Bool, prompted: Bool) -> AutoPastePolicy.Action {
        AutoPastePolicy.decide(enabled: enabled, hasAccess: access, copydIsActive: active, alreadyPrompted: prompted)
    }

    // MARK: - Setting off: a pick only copies, as before

    func testOffAccessInactiveNotPrompted() {
        XCTAssertEqual(decide(enabled: false, access: true, active: false, prompted: false), .none)
    }

    func testOffAccessInactivePrompted() {
        XCTAssertEqual(decide(enabled: false, access: true, active: false, prompted: true), .none)
    }

    func testOffAccessActiveNotPrompted() {
        XCTAssertEqual(decide(enabled: false, access: true, active: true, prompted: false), .none)
    }

    func testOffAccessActivePrompted() {
        XCTAssertEqual(decide(enabled: false, access: true, active: true, prompted: true), .none)
    }

    func testOffNoAccessInactiveNotPrompted() {
        XCTAssertEqual(decide(enabled: false, access: false, active: false, prompted: false), .none,
                       "with the setting off, Copyd never asks for Accessibility")
    }

    func testOffNoAccessInactivePrompted() {
        XCTAssertEqual(decide(enabled: false, access: false, active: false, prompted: true), .none)
    }

    func testOffNoAccessActiveNotPrompted() {
        XCTAssertEqual(decide(enabled: false, access: false, active: true, prompted: false), .none)
    }

    func testOffNoAccessActivePrompted() {
        XCTAssertEqual(decide(enabled: false, access: false, active: true, prompted: true), .none)
    }

    // MARK: - Copyd in front (Settings has focus): ⌘V would land in Copyd

    func testOnAccessActiveNotPrompted() {
        XCTAssertEqual(decide(enabled: true, access: true, active: true, prompted: false), .none)
    }

    func testOnAccessActivePrompted() {
        XCTAssertEqual(decide(enabled: true, access: true, active: true, prompted: true), .none)
    }

    func testOnNoAccessActiveNotPrompted() {
        XCTAssertEqual(decide(enabled: true, access: false, active: true, prompted: false), .none)
    }

    func testOnNoAccessActivePrompted() {
        XCTAssertEqual(decide(enabled: true, access: false, active: true, prompted: true), .none)
    }

    // MARK: - Another app in front

    func testOnAccessInactiveNotPrompted() {
        XCTAssertEqual(decide(enabled: true, access: true, active: false, prompted: false), .paste)
    }

    func testOnAccessInactivePrompted() {
        XCTAssertEqual(decide(enabled: true, access: true, active: false, prompted: true), .paste,
                       "access granted after the prompt pastes")
    }

    func testOnNoAccessInactiveNotPrompted() {
        XCTAssertEqual(decide(enabled: true, access: false, active: false, prompted: false), .requestAccessAndHint)
    }

    func testOnNoAccessInactivePrompted() {
        XCTAssertEqual(decide(enabled: true, access: false, active: false, prompted: true), .hintOnly,
                       "the system prompt is asked for once; later picks only hint")
    }

    // MARK: - Focus ready

    func testFocusReadyOnlyWhenPreviousAppIsFrontmost() {
        XCTAssertTrue(AutoPastePolicy.focusReady(frontmost: 42, previous: 42))
        XCTAssertFalse(AutoPastePolicy.focusReady(frontmost: 7, previous: 42))
        XCTAssertFalse(AutoPastePolicy.focusReady(frontmost: nil, previous: 42))
        XCTAssertFalse(AutoPastePolicy.focusReady(frontmost: 42, previous: nil), "no app to hand back to")
    }

    // MARK: - Giving focus back when the panel hides

    private func restores(target: pid_t?, frontmost: pid_t?, copydInFront: Bool = false) -> Bool {
        AutoPastePolicy.restoresFocus(target: target, frontmost: frontmost, own: 1, copydInFront: copydInFront)
    }

    func testRestoresFocusToTheAppThePanelOpenedOver() {
        XCTAssertTrue(restores(target: 42, frontmost: 42), "the app is still in front but lost its key window")
    }

    func testNoRestoreWithoutATarget() {
        XCTAssertFalse(restores(target: nil, frontmost: 42))
    }

    func testNoRestoreWhenThePanelOpenedOverCopyd() {
        XCTAssertFalse(restores(target: 1, frontmost: 1), "opened from Settings or the menu bar list")
    }

    func testNoRestoreWhenTheUserClickedIntoAnotherApp() {
        XCTAssertFalse(restores(target: 42, frontmost: 7), "that click already gave the other app focus")
    }

    func testNoRestoreWhenCopydWindowTookOver() {
        XCTAssertFalse(restores(target: 42, frontmost: 42, copydInFront: true), "Settings opened from the panel")
    }

    // MARK: - Copyd in front: active, or a titled window opened after the panel did

    private func inFront(active: Bool = false, titled: Set<Int>, atOpen: Set<Int>) -> Bool {
        AutoPastePolicy.copydInFront(isActive: active, titledWindows: titled, titledAtOpen: atOpen)
    }

    func testCopydInFrontWhileActive() {
        XCTAssertTrue(inFront(active: true, titled: [], atOpen: []))
    }

    func testWindowOpenedAfterThePanelCountsAsInFront() {
        XCTAssertTrue(inFront(titled: [7], atOpen: []), "Settings from the sync chip, before its activation lands")
    }

    func testWindowLeftOpenBehindOtherAppsDoesNotCount() {
        XCTAssertFalse(inFront(titled: [7], atOpen: [7]), "Settings left open behind Notes")
        XCTAssertFalse(inFront(titled: [], atOpen: [7]), "closed since the panel opened")
        XCTAssertFalse(inFront(titled: [], atOpen: []))
    }

    func testBackgroundSettingsStillRestoresFocusAndPastes() {
        let copydInFront = inFront(titled: [7], atOpen: [7])
        XCTAssertTrue(restores(target: 42, frontmost: 42, copydInFront: copydInFront),
                      "Copyd Settings visible in the background, target frontmost: focus goes back")
        XCTAssertEqual(AutoPastePolicy.decide(enabled: true, hasAccess: true, copydIsActive: copydInFront, alreadyPrompted: true),
                       .paste)
    }

    // MARK: - Synthetic ⌘V marker

    func testOnlyMarkedEventsCountAsCopydsPaste() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        event.flags = .maskCommand
        XCTAssertFalse(CopydSyntheticPaste.isMarked(event), "the user's own ⌘V")
        event.setIntegerValueField(.eventSourceUserData, value: CopydSyntheticPaste.marker)
        XCTAssertTrue(CopydSyntheticPaste.isMarked(event))
    }
}

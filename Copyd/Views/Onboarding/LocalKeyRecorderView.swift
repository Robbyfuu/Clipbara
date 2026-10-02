import SwiftUI
import AppKit

/// A small recorder control for the panel-local Quick Look key.
/// Click to record, press any key to assign it, Escape to cancel.
struct LocalKeyRecorderView: View {
    @State private var isRecording = false
    @State private var currentKeyCode: UInt16 = QuickLookKeySetting.keyCode
    @State private var eventMonitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            Text(isRecording ? String(localized: "Press a key…") : QuickLookKeySetting.displayName(for: currentKeyCode))
                .font(.system(size: 12, weight: isRecording ? .regular : .semibold))
                .foregroundStyle(isRecording ? Color.secondary : Color.primary)
                .frame(minWidth: 52)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            isRecording ? Color.accentColor : Color.primary.opacity(0.15),
                            lineWidth: isRecording ? 1.5 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help("Click, then press a key to use for Quick Look preview")
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            MainActor.assumeIsolated {
                if keyCode == 53 { // Escape cancels recording
                    stopRecording()
                    return
                }
                guard !QuickLookKeySetting.reservedKeyCodes.contains(keyCode),
                      QuickLookKeySetting.hasKnownName(keyCode) else {
                    NSSound.beep()
                    return
                }
                QuickLookKeySetting.keyCode = keyCode
                currentKeyCode = keyCode
                stopRecording()
            }
            return nil // consume while recording
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

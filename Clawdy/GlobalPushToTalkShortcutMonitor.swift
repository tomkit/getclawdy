//
//  GlobalPushToTalkShortcutMonitor.swift
//  Clawdy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// Fires on every Escape key-down. Consumed by `CompanionManager` as an
    /// escape-hatch out of a wedged annotation mode; gated there on
    /// `isAnnotationModeActive` so Escape is completely inert otherwise.
    let escapeKeyPressedPublisher = PassthroughSubject<Void, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    /// Forcibly clears the persisted pressed-state WITHOUT publishing a transition.
    /// Used by CompanionManager's app-resign / watchdog / escape backstops after
    /// they've already torn down annotation mode directly, so the next genuine
    /// press produces a fresh `.pressed` instead of being swallowed as a repeat.
    func clearHeldShortcutState() {
        isShortcutCurrentlyPressed = false
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if BuddyPushToTalkShortcut.isTapDisableEvent(eventType) {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }

            // While the tap was disabled (a heavy-input window — e.g. a window-manager
            // shortcut grabbing ctrl+option+arrow), any modifier key-UP `flagsChanged`
            // was LOST, so `isShortcutCurrentlyPressed` may be stuck true even though
            // the user already let go. Reconcile against the LIVE hardware modifier
            // state and synthesize the missed release so annotation mode can tear down.
            let liveModifierFlagsRawValue = CGEventSource.flagsState(.combinedSessionState).rawValue
            let liveFlagsContainShortcut = BuddyPushToTalkShortcut.modifierFlagsContainCurrentShortcut(
                modifierFlagsRawValue: liveModifierFlagsRawValue
            )
            if BuddyPushToTalkShortcut.reconciledTransition(
                wasPressed: isShortcutCurrentlyPressed,
                liveFlagsContainShortcut: liveFlagsContainShortcut
            ) == .released {
                isShortcutCurrentlyPressed = false
                shortcutTransitionPublisher.send(.released)
            }

            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Escape is a non-consuming escape-hatch out of a wedged annotation mode.
        // The tap stays `.listenOnly` — we observe Escape and publish a signal but
        // never swallow it, so Escape behaves exactly as normal everywhere else.
        if BuddyPushToTalkShortcut.isEscapeKeyDown(eventType: eventType, keyCode: eventKeyCode) {
            escapeKeyPressedPublisher.send()
            return Unmanaged.passUnretained(event)
        }

        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }
}

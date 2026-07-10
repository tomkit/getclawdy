//
//  MenuBarPanelManager.swift
//  Clawdy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let clawdyDismissPanel = Notification.Name("clawdyDismissPanel")
    static let clawdyShowPanel = Notification.Name("clawdyShowPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var showPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clawdyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        // Lets the push-to-talk handler surface the panel when a required
        // permission is genuinely missing, so the user can grant it.
        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .clawdyShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showPanel()
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeClawdyMenuBarIcon()
        // NOT a template image: a template would be recolored monochrome by macOS to
        // match the menu bar text, hiding the brand red. We want the OpenClaw claw to
        // show its brand colour, so the asset renders as-is.
        button.image?.isTemplate = false
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// The OpenClaw lobster-claw logo used as the menu bar icon, sized to the standard
    /// ~18pt menu bar height. Loaded from the `MenuBarClaw` image set (rendered from the
    /// concept-cute-3 "Two-Tone Gloss" art in OpenClaw red #E5342B); the gloss highlight
    /// disappears at this size, but the claw silhouette still reads. Rendered in brand red
    /// (not as a monochrome template) so the bar shows the OpenClaw colour.
    private func makeClawdyMenuBarIcon() -> NSImage {
        let iconHeight: CGFloat = 18

        // The rendered claw art is square; use the asset if present, otherwise fall
        // back to an empty image so the status item still installs.
        let clawImage = NSImage(named: "MenuBarClaw") ?? NSImage(size: NSSize(width: iconHeight, height: iconHeight))
        clawImage.size = NSSize(width: iconHeight, height: iconHeight)
        return clawImage
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        // Re-detect installed engines every time the panel opens so a CLI the user
        // installed while Clawdy was already running appears in the picker without a
        // relaunch (and a since-uninstalled one drops out). No-ops cheaply when the
        // detected set is unchanged.
        companionManager.rescanInstalledEnginesAndRevalidateSelection()

        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        panel = MenuBarPanelManager.makeMenuBarPanel(
            companionManager: companionManager,
            width: panelWidth,
            height: panelHeight
        )
    }

    /// Builds the menu-bar dropdown panel. This lives in a STATIC factory (rather than
    /// only inline in `createPanel`) so the capturability contract test can build the
    /// REAL panel — and pin its `sharingType` — WITHOUT constructing the whole manager,
    /// whose `init` spawns an `NSStatusItem` that can't render its icon in a headless
    /// test host. `createPanel` delegates here verbatim, so there is no behavior change.
    static func makeMenuBarPanel(
        companionManager: CompanionManager,
        width: CGFloat,
        height: CGFloat
    ) -> NSPanel {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: width)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true
        // Never let this settings/engine-picker panel appear in Clawdy's own model
        // screenshots OR in an external screen recording — it can show engine choice /
        // hints. With `.none`, ScreenCaptureKit skips this window regardless of whether
        // the shareable-content enumeration is cached or fresh (so self-exclusion
        // doesn't depend on a live window snapshot). This is the ONE overlay that stays
        // `.none`; the cursor/annotation/research overlays are all `.readOnly` now.
        menuBarPanel.sharingType = .none

        menuBarPanel.contentView = hostingView
        return menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

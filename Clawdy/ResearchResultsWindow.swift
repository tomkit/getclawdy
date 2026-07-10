//
//  ResearchResultsWindow.swift
//  Clawdy
//
//  An EMBEDDED in-app results window that renders the research deliverable HTML in
//  a WKWebView. We never hand the file to the default browser — the deliverable
//  feels like it came from the companion and stays inside Clawdy's UX. The HTML
//  file is kept on disk (in the per-run temp dir) so the window can be reopened.
//
//  Every Clawdy overlay is `sharingType = .readOnly` (visible to external screen
//  recorders), and this window is too — but it differs from the transient chrome in
//  how it relates to Clawdy's OWN MODEL screenshots. The chrome is EXCLUDED from those
//  screenshots by the capture path's blanket own-app-window exclusion, whereas this
//  window is deliberately EXEMPTED so it STAYS in them: the generated deliverable is
//  content the user opened and wants Clawdy to see, so when they hold push-to-talk over
//  the open results window to iterate on it, the screenshot must contain the rendered
//  page rather than whatever is behind it. To get that exemption the window registers
//  its window number in `CompanionScreenCaptureUtility.capturableOwnWindowNumbers` while
//  visible, which re-includes it via `exceptingWindows` past the app-level exclusion.
//

import AppKit
import QuartzCore
import SwiftUI
import WebKit

@MainActor
final class ResearchResultsWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?

    /// Test seam. An additive offset applied to the window's centered on-screen origin, so a
    /// test can anchor the REAL results window far off-screen — it never flashes in the
    /// top-left during `xcodebuild test` — while the window's creation, size, theme, WKWebView
    /// load, and `ResearchResultsWindowRegistry` binding stay byte-for-byte identical (only
    /// the origin shifts). Production default is `.zero`, so on-screen positioning (centered
    /// on the main screen) is completely unchanged.
    var testAnchorOriginOffset: CGVector = .zero

    /// The transient "Updated" affordance overlay pinned over the content while an
    /// iterate's hot-reload plays. Reused across rapid iterations (never stacked) and
    /// torn down when the window hides/closes so nothing lingers. It lives INSIDE the
    /// (capturable) results window as a plain subview rather than a separate panel, so
    /// it can never touch the `ResearchResultsWindowRegistry` capturable-window logic —
    /// and it fades out well within a second, so it isn't what a follow-up screenshot
    /// captures (that's taken at the NEXT push-to-talk press, long after this is gone).
    private var updateAffordanceOverlay: ResearchResultsUpdateAffordanceView?
    /// The pending removal of the affordance overlay, kept so a fresh refresh can cancel
    /// and replace it — multiple rapid iterations must not stack overlapping timers.
    private var affordanceDismissWorkItem: DispatchWorkItem?

    /// The research session whose page this window is currently showing. Set on every
    /// `show(...)` and used to bind this on-screen window to its session in
    /// `ResearchResultsWindowRegistry`, so a spoken follow-up routes to THIS page's
    /// session when this window is frontmost — regardless of click focus.
    private var boundSessionID: ResearchSessionID?

    /// The window number this controller last registered a registry binding for, kept
    /// as a plain value so `deinit` can drop the binding without touching AppKit off the
    /// main actor. 0 when nothing is currently bound.
    private var boundWindowNumber: Int = 0

    /// Defense in depth: if this controller is deallocated while a binding is still live
    /// (its window was shown but never explicitly hidden/closed — e.g. its owning session
    /// was dropped), drop the registry binding so `frontmostSessionID()` can never resolve
    /// to a dead session. The registry is main-actor isolated; hop to it with the captured
    /// window number (a value type, safe to read from this nonisolated deinit).
    deinit {
        let windowNumberToUnbind = boundWindowNumber
        guard windowNumberToUnbind > 0 else { return }
        Task { @MainActor in
            ResearchResultsWindowRegistry.shared.unbind(windowNumber: windowNumberToUnbind)
        }
    }

    /// Opens (or re-opens) the results window showing `htmlFileURL`, titled with
    /// the originating research task. `sessionID` is the research session that produced
    /// the page, bound to this window so a follow-up spoken while it's frontmost
    /// continues that session's thread. Grants the WKWebView read access to the file's
    /// own directory so relative assets (if any) resolve.
    func show(htmlFileURL: URL, title: String, sessionID: ResearchSessionID) {
        boundSessionID = sessionID
        createWindowIfNeeded()
        guard let window, let webView else { return }

        window.title = title.isEmpty ? "Research" : title

        // Load the local file, granting read access to its containing directory so
        // the self-contained page (and any sibling asset) can load via file://.
        let readAccessDirectory = htmlFileURL.deletingLastPathComponent()
        webView.loadFileURL(htmlFileURL, allowingReadAccessTo: readAccessDirectory)

        if let screen = NSScreen.main {
            let windowSize = window.frame.size
            let visibleFrame = screen.visibleFrame
            let origin = CGPoint(
                x: visibleFrame.midX - windowSize.width / 2 + testAnchorOriginOffset.dx,
                y: visibleFrame.midY - windowSize.height / 2 + testAnchorOriginOffset.dy
            )
            window.setFrameOrigin(origin)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Now that the window is on screen it has a valid window number. Register
        // it as capturable so the screenshot path exempts it from the blanket
        // own-app-window exclusion (see the file header).
        registerAsCapturable()
    }

    /// Reloads the results window after an ITERATE follow-up REWROTE report.html and
    /// plays a subtle "this just updated" affordance so the change is visible instead of
    /// the page silently swapping. Only ever called on the rewrite path — a pure
    /// question follow-up refreshes nothing (gated in `ResearchSession`). The reload
    /// itself reuses `show(...)` so the bring-forward + capturable re-registration are
    /// unchanged; the affordance is purely additive. Reduce Motion (read here so the
    /// caller stays AppKit-free) collapses the tween to a near-instant swap.
    func refreshWithUpdate(htmlFileURL: URL, title: String, sessionID: ResearchSessionID) {
        let reduceMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animationPlan = ResearchResultsRefreshAnimation.plan(
            followUpKind: .rewrite,
            reduceMotionEnabled: reduceMotionEnabled
        )
        show(htmlFileURL: htmlFileURL, title: title, sessionID: sessionID)
        playUpdateAffordance(animationPlan)
    }

    func hide() {
        cancelInFlightAffordance()
        unregisterAsCapturable()
        window?.orderOut(nil)
    }

    /// Whether the results window is currently on screen. Drives the follow-up view
    /// refresh: after an ITERATE turn rewrites report.html we only reload the
    /// WKWebView when the user actually has the window open (never pop it open behind
    /// their back on a turn they didn't ask to re-view).
    var isVisible: Bool { window?.isVisible ?? false }

    /// Test hook: the underlying window, so a test can retain it across the controller's
    /// dealloc and prove `deinit` (not the window-close path) drops the registry binding.
    var windowForTesting: NSWindow? { window }

    /// The user clicked the window's close button. Drop the capturable
    /// registration so a stale window number can't linger past the window's life, and
    /// tear down any in-flight update affordance so no timer/animation leaks past close.
    func windowWillClose(_ notification: Notification) {
        cancelInFlightAffordance()
        unregisterAsCapturable()
    }

    // MARK: - Render-time broken-image safety net (layer B)

    /// After each successful load, run the broken-image sweep so any `<img>` that
    /// failed to render is replaced by the same OpenClaw-red "Image unavailable"
    /// placeholder the pre-display HTTP validation uses. This is the render-time net
    /// under the deterministic pre-display pass: it catches images that die between
    /// validation and view, or that a full render proves broken. Idempotent and cheap.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(Self.brokenImageSweepJavaScript, completionHandler: nil)
    }

    /// Self-contained JS that, once per page load, replaces every already-broken
    /// `<img>` (loaded but `naturalWidth === 0`) with an inline placeholder and
    /// installs an `error` handler on the rest so an image that fails to load LATER is
    /// swapped too. Guarded by a per-run flag + a per-image data attribute so repeated
    /// injection (e.g. after a reload) never double-processes. The placeholder markup
    /// and styling mirror `ResearchImageValidator.brokenImagePlaceholderHTML`.
    private static let brokenImageSweepJavaScript = """
    (function () {
      if (window.__clawdyBrokenImageSweepInstalled) {
        if (typeof window.__clawdySweepBrokenImages === 'function') { window.__clawdySweepBrokenImages(); }
        return;
      }
      window.__clawdyBrokenImageSweepInstalled = true;

      var PLACEHOLDER_STYLE = "display:inline-flex;align-items:center;justify-content:center;box-sizing:border-box;min-width:140px;min-height:100px;max-width:100%;padding:14px 18px;margin:2px;border:1px solid #E5342B;border-radius:10px;background:#FDECEA;color:#C42B22;font-family:-apple-system,system-ui,'Segoe UI',sans-serif;font-size:12px;font-weight:600;line-height:1.35;text-align:center;";

      function replaceWithPlaceholder(img) {
        if (!img || img.__clawdyReplaced) { return; }
        img.__clawdyReplaced = true;
        var placeholder = document.createElement('span');
        placeholder.setAttribute('style', PLACEHOLDER_STYLE);
        placeholder.textContent = 'Image unavailable';
        if (img.parentNode) { img.parentNode.replaceChild(placeholder, img); }
      }

      window.__clawdySweepBrokenImages = function () {
        var images = document.querySelectorAll('img');
        for (var i = 0; i < images.length; i++) {
          var img = images[i];
          if (img.__clawdyReplaced || img.__clawdyWatched) { continue; }
          img.__clawdyWatched = true;
          if (img.complete) {
            if (img.naturalWidth === 0) { replaceWithPlaceholder(img); }
          } else {
            img.addEventListener('error', function (event) { replaceWithPlaceholder(event.target); });
          }
        }
      };

      window.__clawdySweepBrokenImages();
    })();
    """

    // MARK: - Update affordance (hot-reload "this just updated" tween)

    /// Plays (or, under Reduce Motion, minimally shows) the "Updated" affordance for an
    /// iterate's hot-reload. Robust against rapid re-iterations: any in-flight affordance
    /// is cancelled and REPLACED first, so overlays and dismiss timers never stack.
    private func playUpdateAffordance(_ animationPlan: ResearchResultsRefreshAnimationPlan) {
        guard animationPlan.showsUpdatedAffordance,
              let window,
              let contentView = window.contentView else { return }

        // Cancel + replace any affordance already on screen so nothing overlaps.
        cancelInFlightAffordance()

        // Full motion only: cross-fade the reloaded WKWebView content in. Reduce Motion
        // leaves the swap instant (contentCrossFadeDuration is 0 in that plan anyway).
        if animationPlan.animates, let webView {
            webView.wantsLayer = true
            webView.layer?.removeAnimation(forKey: ResearchResultsRefreshAnimation.contentCrossFadeAnimationKey)
            let crossFade = CABasicAnimation(keyPath: "opacity")
            crossFade.fromValue = 0.25
            crossFade.toValue = 1.0
            crossFade.duration = animationPlan.contentCrossFadeDuration
            crossFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            webView.layer?.add(crossFade, forKey: ResearchResultsRefreshAnimation.contentCrossFadeAnimationKey)
        }

        // Reuse the existing overlay if one is still parented; otherwise create it. Then
        // lift it above the webView and size it to the content so it tracks resizes.
        let overlay = updateAffordanceOverlay ?? ResearchResultsUpdateAffordanceView()
        updateAffordanceOverlay = overlay
        overlay.frame = contentView.bounds
        overlay.autoresizingMask = [.width, .height]
        contentView.addSubview(overlay, positioned: .above, relativeTo: nil)

        overlay.play(animationPlan: animationPlan)

        // Remove the overlay after its full lifetime. The work item is cancellable so a
        // rapid re-iteration replaces it instead of racing two removals.
        let dismissWorkItem = DispatchWorkItem { [weak self, weak overlay] in
            overlay?.cancelAnimations()
            overlay?.removeFromSuperview()
            if self?.updateAffordanceOverlay === overlay {
                self?.updateAffordanceOverlay = nil
            }
            self?.affordanceDismissWorkItem = nil
        }
        affordanceDismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + animationPlan.totalAffordanceDuration,
            execute: dismissWorkItem
        )
    }

    /// Cancels a pending affordance removal and tears the overlay down immediately, so a
    /// replacement refresh (or a window hide/close) never leaves a stacked overlay or a
    /// live timer behind. Also removes the WKWebView content cross-fade so a mid-flight
    /// fade is torn down on hide/close (not just on the next refresh), and resets the
    /// layer opacity to its resting value so a closed-then-reopened window isn't stuck
    /// mid-transition.
    private func cancelInFlightAffordance() {
        affordanceDismissWorkItem?.cancel()
        affordanceDismissWorkItem = nil
        updateAffordanceOverlay?.cancelAnimations()
        updateAffordanceOverlay?.removeFromSuperview()
        updateAffordanceOverlay = nil
        if let webViewLayer = webView?.layer {
            for animationKey in ResearchResultsRefreshAnimation.webViewAnimationKeysToClearOnCancel {
                webViewLayer.removeAnimation(forKey: animationKey)
            }
            webViewLayer.opacity = 1.0
        }
    }

    // MARK: - Private

    /// Adds the (now on-screen) window's number to the capture allow-list so the
    /// screenshot path keeps it visible. The number is only valid once the window
    /// has been ordered front, so this must be called after `makeKeyAndOrderFront`.
    private func registerAsCapturable() {
        guard let window else { return }
        let windowNumber = window.windowNumber
        guard windowNumber > 0 else { return }
        CompanionScreenCaptureUtility.registerCapturableWindow(CGWindowID(windowNumber))
        // Bind this on-screen window to its session so a follow-up spoken while it's
        // frontmost routes to THIS page's session (independent of click focus).
        if let boundSessionID {
            ResearchResultsWindowRegistry.shared.bind(windowNumber: windowNumber, sessionID: boundSessionID)
            boundWindowNumber = windowNumber
        }
    }

    /// Removes this window's number from the capture allow-list (window hidden or
    /// closed) so the app's own-window exclusion applies again if the number is
    /// ever reused.
    private func unregisterAsCapturable() {
        guard let window else { return }
        let windowNumber = window.windowNumber
        guard windowNumber > 0 else { return }
        CompanionScreenCaptureUtility.unregisterCapturableWindow(CGWindowID(windowNumber))
        // Drop the session binding too so a hidden/closed window can't resolve a
        // follow-up to a stale session if its window number is later reused.
        ResearchResultsWindowRegistry.shared.unbind(windowNumber: windowNumber)
        boundWindowNumber = 0
    }

    private func createWindowIfNeeded() {
        if window != nil { return }

        let windowContentSize = NSSize(width: 900, height: 680)

        // An OPAQUE, themed content container is the window's content view, with the WKWebView
        // filling it edge-to-edge. There is NO transparent margin and NO floating glow card:
        // the window's real, VISIBLE defined edge is the standard system window frame + titlebar
        // set up below — exactly the same window family as the History window, an opaque titled
        // NSWindow. The themed fill (`DS.Colors.background`, the History window's own base fill)
        // shows behind the page while it loads / during resize, so the surface never flashes
        // transparent. The transient hot-reload pulse (`ResearchResultsUpdateAffordanceView`)
        // still plays over this content as an in-window subview.
        let containerView = NSView(frame: NSRect(origin: .zero, size: windowContentSize))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = ResearchResultsWindowStyle.backgroundColor.cgColor

        let configuration = WKWebViewConfiguration()
        let resultsWebView = WKWebView(frame: containerView.bounds, configuration: configuration)
        resultsWebView.autoresizingMask = [.width, .height]
        // Render-time safety net (layer B): after each load, hide/replace any <img>
        // that failed to render, catching anything that slips past the pre-display
        // HTTP validation or dies between validation and view.
        resultsWebView.navigationDelegate = self
        self.webView = resultsWebView
        containerView.addSubview(resultsWebView)

        let resultsWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowContentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // A standard OPAQUE titled window — a real system titlebar (showing the research task
        // title) and a real window frame — matching the History window (`ResearchHistoryWindow`),
        // so the two read as one window family with a clearly-defined edge. This replaces the old
        // borderless transparent glow card, whose only "edge" was an invisible hairline and so
        // read as no border at all.
        resultsWindow.titlebarAppearsTransparent = false
        resultsWindow.isReleasedWhenClosed = false
        resultsWindow.backgroundColor = ResearchResultsWindowStyle.backgroundColor
        resultsWindow.contentView = containerView
        resultsWindow.collectionBehavior = [.fullScreenPrimary]
        resultsWindow.minSize = ResearchResultsWindowStyle.minimumContentSize
        resultsWindow.delegate = self
        // Deliberately capturable (default `.readOnly`): this is the deliverable
        // the user wants Clawdy to see when they iterate on it. Being on-screen is
        // not enough — the capture path also blanket-excludes all own-app windows,
        // so `show()` additionally registers this window as capturable.
        resultsWindow.sharingType = .readOnly
        window = resultsWindow
    }
}

/// The transient "Updated" affordance drawn over the results page on an iterate's
/// hot-reload: a brief brand-red (`#E5342B`) glow pulse around the content edge plus a
/// small "Updated" pill that fades in, holds, and fades out. It is purely decorative —
/// `hitTest` returns nil so every click passes straight through to the WKWebView — and
/// it draws NOTHING until `play(animationPlan:)` runs, so an idle overlay is invisible.
@MainActor
private final class ResearchResultsUpdateAffordanceView: NSView {

    /// The brand red (`DS.Colors.openClawRed`, #E5342B) as an NSColor — used ONLY for
    /// the non-text glow border/shadow around the content edge. Routed through the DS
    /// token so there's a single source of truth for the red.
    private static let brandRed = NSColor(DS.Colors.openClawRed)

    /// The AA-safe deeper red (`DS.Colors.accentButtonFill`, #C42B22) as an NSColor —
    /// used for the "Updated" PILL fill, which sits behind WHITE text, so it must clear
    /// WCAG AA (the lighter brand red would not).
    private static let pillFill = DS.Colors.accentButtonFillNSColor

    /// The glow border pulsed around the content edge (full motion only).
    private let glowBorderLayer = CALayer()
    /// The rounded "Updated" pill, hidden (opacity 0) until played.
    private let pillContainer = NSView()
    private let pillLabel = NSTextField(labelWithString: "Updated")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        glowBorderLayer.borderColor = Self.brandRed.cgColor
        glowBorderLayer.borderWidth = 3
        glowBorderLayer.cornerRadius = DS.CornerRadius.large
        glowBorderLayer.opacity = 0
        glowBorderLayer.shadowColor = Self.brandRed.cgColor
        glowBorderLayer.shadowRadius = 12
        glowBorderLayer.shadowOpacity = 0.9
        glowBorderLayer.shadowOffset = .zero
        layer?.addSublayer(glowBorderLayer)

        pillContainer.wantsLayer = true
        pillContainer.layer?.backgroundColor = Self.pillFill.cgColor
        pillContainer.layer?.cornerRadius = DS.CornerRadius.large
        pillContainer.layer?.opacity = 0
        pillContainer.translatesAutoresizingMaskIntoConstraints = true

        pillLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        pillLabel.textColor = .white
        pillLabel.backgroundColor = .clear
        pillLabel.isBezeled = false
        pillLabel.isEditable = false
        pillLabel.alignment = .center
        pillLabel.sizeToFit()
        pillLabel.frame = NSRect(
            x: 12,
            y: 4,
            width: pillLabel.frame.width,
            height: pillLabel.frame.height
        )
        pillContainer.frame = NSRect(
            x: 0,
            y: 0,
            width: pillLabel.frame.width + 24,
            height: pillLabel.frame.height + 8
        )
        pillContainer.addSubview(pillLabel)
        addSubview(pillContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Decorative overlay — never intercept clicks; they belong to the page underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // Inset the glow slightly so its rounded border reads inside the content edge.
        glowBorderLayer.frame = bounds.insetBy(dx: 2, dy: 2)
        // Pin the pill to the top-center of the content.
        let pillSize = pillContainer.frame.size
        pillContainer.frame = NSRect(
            x: (bounds.width - pillSize.width) / 2,
            y: bounds.height - pillSize.height - 16,
            width: pillSize.width,
            height: pillSize.height
        )
    }

    /// Plays the affordance per the resolved plan. Full motion runs the glow pulse and a
    /// fade-in/hold/fade-out on the pill; Reduce Motion skips the glow entirely and shows
    /// the pill with only a minimal opacity settle (no motion). Every animation ends with
    /// the layer back at opacity 0, so once the controller removes the view nothing
    /// lingers.
    func play(animationPlan: ResearchResultsRefreshAnimationPlan) {
        cancelAnimations()
        needsLayout = true
        layoutSubtreeIfNeeded()

        let fadeIn = animationPlan.affordanceFadeInDuration
        let hold = animationPlan.affordanceHoldDuration
        let fadeOut = animationPlan.affordanceFadeOutDuration
        let total = max(animationPlan.totalAffordanceDuration, 0.0001)

        // The glow pulse is "motion" — omit it under Reduce Motion.
        if animationPlan.animates {
            let glowPulse = CAKeyframeAnimation(keyPath: "opacity")
            glowPulse.values = [0.0, 0.9, 0.0]
            glowPulse.keyTimes = [0.0, NSNumber(value: (fadeIn + hold * 0.25) / total), 1.0]
            glowPulse.duration = total
            glowPulse.isRemovedOnCompletion = true
            glowBorderLayer.add(glowPulse, forKey: "researchUpdateGlow")
        }

        // The pill: fade in → hold → fade out, ending hidden. Reduce Motion just uses the
        // minimal fade durations baked into the plan (a small opacity change, not motion).
        let pillFade = CAKeyframeAnimation(keyPath: "opacity")
        pillFade.values = [0.0, 1.0, 1.0, 0.0]
        pillFade.keyTimes = [
            0.0,
            NSNumber(value: fadeIn / total),
            NSNumber(value: (fadeIn + hold) / total),
            1.0
        ]
        pillFade.duration = total
        pillFade.isRemovedOnCompletion = true
        pillContainer.layer?.add(pillFade, forKey: "researchUpdatePill")
    }

    /// Removes every affordance animation immediately (used on replace / hide / close) so
    /// no pulse survives into a later refresh or past the window's life.
    func cancelAnimations() {
        glowBorderLayer.removeAllAnimations()
        pillContainer.layer?.removeAllAnimations()
    }
}

// MARK: - Results window theming

/// The theming for the results window's opaque frame — the calm base fill that makes it a
/// standard, DEFINED, opaque window matching the History window (`ResearchHistoryWindow`), rather
/// than the old borderless transparent glow card whose only edge was an invisible hairline. The
/// window's visible border is the real system titlebar + frame; this fill is the History window's
/// own base surface (`DS.Colors.background`), so the two windows read as one system.
///
/// Pure values, so a test can assert the theming (DS tokens + minimum size) without rendering a
/// window.
enum ResearchResultsWindowStyle {
    /// The opaque window/content fill — the History window's base surface token (`DS.Colors.background`,
    /// its own main-window fill), bridged to `NSColor` for this AppKit `WKWebView` window. Shown
    /// behind the page while it loads / during resize so the surface never flashes transparent.
    static let backgroundColor: NSColor = NSColor(DS.Colors.background)

    /// The smallest the resizable window may become — the same lower bound the History window
    /// uses so both windows keep a sensible, readable minimum footprint.
    static let minimumContentSize: NSSize = NSSize(width: 640, height: 460)
}

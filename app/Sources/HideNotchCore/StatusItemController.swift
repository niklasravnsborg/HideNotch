import AppKit
import Observation
import os
import SwiftUI

@MainActor
@Observable
public final class StatusItemController: NSObject, NSPopoverDelegate {
    @ObservationIgnored private static let log = Logger(subsystem: "com.niklasravnsborg.hidenotch", category: "StatusItem")

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let overlay: OverlayController
    @ObservationIgnored private let loginItem: LoginItemControlling
    @ObservationIgnored private let confirmHidingIcon: @MainActor () -> Bool
    @ObservationIgnored private let informSystemBackground: @MainActor () -> Void
    @ObservationIgnored private let informDisallowedIcon: @MainActor () -> Void
    /// Syncs the wallpapers and returns their state. Calls the completion later, once the changes show.
    @ObservationIgnored private let paintWallpaper: @MainActor (WallpaperTarget, @escaping @MainActor () -> Void)
        -> WallpaperState
    @ObservationIgnored private var wallpaperTarget = WallpaperTarget()
    /// Counts transitions, so a superseded one stops before parking the overlay.
    @ObservationIgnored private var transition = 0
    @ObservationIgnored private var isTransitioning = false
    @ObservationIgnored private(set) var statusItem: NSStatusItem?
    @ObservationIgnored let popover = NSPopover()
    @ObservationIgnored private let hint = NSPopover()
    @ObservationIgnored private var outsideClickMonitor: Any?
    @ObservationIgnored private var hintClickMonitor: Any?
    @ObservationIgnored private let warning = NSPopover()
    @ObservationIgnored private var warningClickMonitor: Any?
    @ObservationIgnored private var wasWarning = false
    @ObservationIgnored private var hidesWarningThisSession = false
    /// Keeps a hidden icon visible while the warning points at it.
    @ObservationIgnored private var showsIconForWarning = false
    @ObservationIgnored let updates: Updater
    private var loginItemFailed = false

    private(set) var isOverlayEnabled = false
    private(set) var isRoundedCornersEnabled = false
    private(set) var isScreensWithoutNotchEnabled = false
    private(set) var isWallpaperPaintable = true
    private(set) var isMenuBarCrowded = false
    private(set) var isMenuBarIconShown = false
    private(set) var isLaunchAtLoginEnabled = false
    private(set) var launchAtLoginTitle = L10n.launchAtLogin

    public init(
        preferences: Preferences, overlay: OverlayController, loginItem: LoginItemControlling,
        updates: Updater = Updater(),
        confirmHidingIcon: @escaping @MainActor () -> Bool = StatusItemController.explainHiddenIcon,
        informSystemBackground: @escaping @MainActor () -> Void = StatusItemController.explainSystemBackground,
        informDisallowedIcon: @escaping @MainActor () -> Void = StatusItemController.explainDisallowedIcon,
        paintWallpaper: @escaping @MainActor (WallpaperTarget, @escaping @MainActor () -> Void)
            -> WallpaperState = {
            $1()
            return WallpaperState(paintable: true, settled: true)
        }
    ) {
        self.preferences = preferences
        self.overlay = overlay
        self.loginItem = loginItem
        self.updates = updates
        self.confirmHidingIcon = confirmHidingIcon
        self.informSystemBackground = informSystemBackground
        self.informDisallowedIcon = informDisallowedIcon
        self.paintWallpaper = paintWallpaper
        super.init()

        popover.behavior = .transient
        popover.delegate = self
        let content = NSHostingController(rootView: SettingsView(controller: self))
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content

        hint.behavior = .applicationDefined
        let hintContent = NSHostingController(rootView: HintView { [weak self] in self?.togglePopover() })
        hintContent.sizingOptions = .preferredContentSize
        hint.contentViewController = hintContent

        warning.behavior = .applicationDefined
        let warningContent = NSHostingController(rootView: WarningView(
            dismiss: { [weak self] in
                self?.hidesWarningThisSession = true
                self?.closeWarning()
            },
            dismissForever: { [weak self] in
                self?.preferences.hidesWallpaperWarning = true
                self?.closeWarning()
            }))
        warningContent.sizingOptions = .preferredContentSize
        warning.contentViewController = warningContent
        syncState()
    }

    public func install() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NotchIcon.menuBarImage()
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        syncState()
    }

    @objc private func togglePopover() {
        closeHint()
        closeWarning()
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // The cooperative activate() is refused while another app is frontmost.
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // macOS may refuse to activate an accessory app, and then .transient misses clicks in other apps.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.popover.performClose(nil) }
            }
        }
    }

    public func popoverWillShow(_ notification: Notification) {
        syncState()
    }

    public func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    /// Points at the icon when HideNotch launches with the notch still visible.
    public func showHint(after delay: Duration = .seconds(1)) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !self.preferences.overlayEnabled, !self.popover.isShown,
                  let button = self.statusItem?.button,
                  button.window?.occlusionState.contains(.visible) == true else { return }
            self.hint.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.hintClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeHint() }
            }
        }
    }

    /// Points out, once per occurrence, that an animated wallpaper is showing instead of the black bar.
    public func updateWallpaperWarning(crowded: Bool) {
        let warns = overlay.isEnabled && !isWallpaperPaintable && crowded
        defer { wasWarning = warns }
        if !warns && warning.isShown { closeWarning() }
        guard warns, !wasWarning, !preferences.hidesWallpaperWarning, !hidesWarningThisSession,
              !popover.isShown, !warning.isShown, let statusItem else { return }
        closeHint()
        let revealsIcon = !statusItem.isVisible
        showsIconForWarning = true
        syncState()
        Task { @MainActor [weak self] in
            // Give a revealed icon time to appear before anchoring the warning to it.
            if revealsIcon { try? await Task.sleep(for: .milliseconds(300)) }
            guard let self, let button = statusItem.button, self.wasWarning else {
                self?.showsIconForWarning = false
                self?.syncState()
                return
            }
            self.warning.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.warningClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeWarning() }
            }
        }
    }

    private func closeWarning() {
        warning.close()
        if let warningClickMonitor { NSEvent.removeMonitor(warningClickMonitor) }
        warningClickMonitor = nil
        showsIconForWarning = false
        syncState()
    }

    private func closeHint() {
        hint.close()
        if let hintClickMonitor { NSEvent.removeMonitor(hintClickMonitor) }
        hintClickMonitor = nil
    }

    func toggleRoundedCorners() {
        preferences.roundedCornersEnabled.toggle()
        applyPreferences(addingBlack: preferences.roundedCornersEnabled)
    }

    func toggleScreensWithoutNotch() {
        preferences.screensWithoutNotchEnabled.toggle()
        applyPreferences(addingBlack: preferences.screensWithoutNotchEnabled)
    }

    /// Keeps the overlay's animations visible against the plain wallpaper: black goes onto the wallpaper
    /// only after the overlay has animated in, and comes off it before the overlay animates out.
    /// In between, the overlay steps aside while a painted wallpaper shows the same black.
    public func applyPreferences(addingBlack: Bool = true) {
        transition += 1
        let current = transition
        isTransitioning = true
        overlay.isParked = false
        let afterAnimation = { [weak self] (next: @escaping @MainActor () -> Void) in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(ScreenMaskAnimation.transitionDuration))
                guard self?.transition == current else { return }
                next()
            }
        }
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.transition == current else { return }
            self.isTransitioning = false
            self.parkOverlayIfCovered()
        }
        if addingBlack {
            applyOverlayPreferences()
            afterAnimation { [weak self] in self?.applyWallpaperPreferences(completion: finish) }
        } else {
            // Start the hide animation immediately while the original wallpaper is restored.
            // Both transitions take roughly the same time, avoiding a pause before the mask moves.
            applyOverlayPreferences()
            applyWallpaperPreferences(completion: finish)
        }
    }

    private func applyOverlayPreferences() {
        overlay.roundedCornersEnabled = preferences.roundedCornersEnabled
        overlay.screensWithoutNotchEnabled = preferences.screensWithoutNotchEnabled
        overlay.isEnabled = preferences.overlayEnabled
        syncState()
    }

    private func applyWallpaperPreferences(completion: @escaping @MainActor () -> Void = {}) {
        wallpaperTarget = WallpaperTarget(
            active: preferences.overlayEnabled,
            includingScreensWithoutNotch: preferences.screensWithoutNotchEnabled,
            roundedCorners: preferences.roundedCornersEnabled)
        isWallpaperPaintable = paintWallpaper(wallpaperTarget, completion).paintable
    }

    /// Brings the wallpapers in line again, for example after the user picked a new one. The overlay
    /// covers the screens until the new wallpaper shows the black.
    public func syncWallpaper() {
        let state = paintWallpaper(wallpaperTarget) { [weak self] in self?.parkOverlayIfCovered() }
        isWallpaperPaintable = state.paintable
        if !isTransitioning && !(state.paintable && state.settled) {
            overlay.isParked = false
        }
    }

    private func parkOverlayIfCovered() {
        guard !isTransitioning else { return }
        overlay.isParked = wallpaperTarget.active && isWallpaperPaintable
    }

    /// Puts the original wallpapers back, for quitting.
    public func restoreWallpaper(completion: @escaping @MainActor () -> Void) {
        transition += 1
        isTransitioning = true
        overlay.isParked = false
        wallpaperTarget.active = false
        _ = paintWallpaper(wallpaperTarget, completion)
    }

    func toggleMenuBarIcon() {
        popover.close()
        preferences.showMenuBarIcon.toggle()
        syncState()
        if !preferences.showMenuBarIcon && !confirmHidingIcon() {
            restoreMenuBarIcon()
        }
    }

    /// Reopening the running app restores access to its controls.
    public func restoreMenuBarIcon() {
        preferences.showMenuBarIcon = true
        syncState()
    }

    /// macOS doesn't expose "Allow in the Menu Bar", but a disallowed icon's window never becomes visible.
    public func checkIconVisibility(after delay: Duration = .seconds(1)) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.preferences.showMenuBarIcon,
                  let window = self.statusItem?.button?.window,
                  !window.occlusionState.contains(.visible) else { return }
            self.informDisallowedIcon()
        }
    }

    func toggleOverlay() {
        preferences.overlayEnabled.toggle()
        applyPreferences(addingBlack: preferences.overlayEnabled)
    }

    /// Stops hiding the notch when the system background would cover the overlay.
    public func disableOverlayForSystemBackground() {
        guard overlay.isEnabled else { return }
        preferences.overlayEnabled = false
        overlay.isParked = false
        overlay.disableImmediately()
        applyWallpaperPreferences()
        restoreMenuBarIcon()
        informSystemBackground()
    }

    public static func explainSystemBackground() {
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = L10n.systemBackgroundAlertTitle
        alert.informativeText = L10n.systemBackgroundAlertMessage
        alert.addButton(withTitle: L10n.hiddenIconAlertConfirm)
        alert.runModal()
    }

    public static func explainDisallowedIcon() {
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = L10n.disallowedIconAlertTitle
        alert.informativeText = L10n.disallowedIconAlertMessage
        alert.addButton(withTitle: L10n.disallowedIconAlertOpenSettings)
        alert.addButton(withTitle: L10n.hiddenIconAlertConfirm)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Activates the (accessory) app before presenting the alert, so it doesn't appear behind other windows.
    public static func explainHiddenIcon() -> Bool {
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = L10n.hiddenIconAlertTitle
        alert.informativeText = L10n.hiddenIconAlertMessage
        alert.addButton(withTitle: L10n.hiddenIconAlertConfirm)
        alert.addButton(withTitle: L10n.hiddenIconAlertCancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func toggleLoginItem() {
        if loginItem.state == .requiresApproval {
            loginItem.openSystemSettings()
            syncState()
            return
        }
        do {
            try loginItem.setEnabled(loginItem.state != .enabled)
            loginItemFailed = false
        } catch {
            loginItemFailed = true
            Self.log.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
        }
        syncState()
    }

    /// Turns on launch at login once, the first time HideNotch runs from an Applications folder.
    /// Elsewhere (a DMG, Downloads) macOS may run a translocated copy whose path won't survive a reboot.
    public func enableLoginItemOnFirstLaunch(bundlePath: String = Bundle.main.bundlePath,
                                            home: String = NSHomeDirectory()) {
        let installed = bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/Applications/")
        guard installed, !preferences.didSetUpLoginItem else { return }
        preferences.didSetUpLoginItem = true
        guard loginItem.state == .disabled else { return }
        do {
            try loginItem.setEnabled(true)
        } catch {
            Self.log.error("Login item setup failed: \(error.localizedDescription, privacy: .public)")
        }
        syncState()
    }

    func visitWebsite() {
        popover.close()
        NSWorkspace.shared.open(URL(string: "https://hidenotch.app")!)
    }

    func checkForUpdates() {
        popover.close()
        NSApplication.shared.activate()
        updates.checkForUpdates()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func syncState() {
        isOverlayEnabled = preferences.overlayEnabled
        isRoundedCornersEnabled = preferences.roundedCornersEnabled
        isScreensWithoutNotchEnabled = preferences.screensWithoutNotchEnabled
        isMenuBarIconShown = preferences.showMenuBarIcon
        statusItem?.isVisible = preferences.showMenuBarIcon || showsIconForWarning
        isLaunchAtLoginEnabled = loginItem.state == .enabled
        isMenuBarCrowded = overlay.isEnabled && MenuBarCrowding.isCrowded(screens: overlay.windows.map(\.frame))
        if loginItemFailed {
            launchAtLoginTitle = L10n.launchAtLoginFailed
        } else if loginItem.state == .requiresApproval {
            launchAtLoginTitle = L10n.launchAtLoginNeedsApproval
        } else {
            launchAtLoginTitle = L10n.launchAtLogin
        }
    }
}

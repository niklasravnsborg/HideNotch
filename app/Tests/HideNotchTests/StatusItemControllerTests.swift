import AppKit
import Testing
@testable import HideNotchCore

@MainActor
struct StatusItemControllerTests {
    let suite = "HideNotchTests.\(UUID().uuidString)"
    let screens = FakeScreens()
    let factory = WindowFactory()
    let login = FakeLoginItem()
    let confirm = ConfirmSpy()
    let backgroundAlert = ConfirmSpy()

    func makeSUT(overlayEnabled: Bool = true) -> (StatusItemController, Preferences, OverlayController) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        prefs.overlayEnabled = overlayEnabled
        screens.list = [Screens.notched]
        let overlay = OverlayController(screens: screens, makeWindow: factory.make)
        overlay.isEnabled = prefs.overlayEnabled
        let sut = StatusItemController(
            preferences: prefs, overlay: overlay, loginItem: login, confirmHidingIcon: confirm.ask,
            informSystemBackground: { _ = backgroundAlert.ask() })
        return (sut, prefs, overlay)
    }

    @Test(arguments: [true, false])
    func overlayStepsAsideOnlyForAPaintedWallpaper(paintable: Bool) async throws {
        let (_, prefs, overlay) = makeSUT(overlayEnabled: false)
        let sut = StatusItemController(
            preferences: prefs, overlay: overlay, loginItem: login, confirmHidingIcon: confirm.ask,
            paintWallpaper: { _, completion in
                // Like WallpaperPainter, report the result before completing.
                Task { @MainActor in completion() }
                return WallpaperState(paintable: paintable, settled: true)
            })
        sut.toggleOverlay()
        #expect(!overlay.isParked)
        try await Task.sleep(for: .seconds(ScreenMaskAnimation.transitionDuration + 0.2))
        #expect(overlay.isParked == paintable)
        sut.toggleOverlay()
        #expect(!overlay.isParked)
    }

    @Test func turningOffStartsHidingBeforeTheWallpaperFinishes() {
        let (_, prefs, overlay) = makeSUT()
        var targets: [WallpaperTarget] = []
        var finish: (@MainActor () -> Void)?
        let sut = StatusItemController(
            preferences: prefs, overlay: overlay, loginItem: login, confirmHidingIcon: confirm.ask,
            paintWallpaper: { target, completion in
                targets.append(target)
                finish = completion
                return WallpaperState(paintable: true, settled: false)
            })
        sut.toggleOverlay()
        #expect(targets.last?.active == false)
        #expect(!overlay.isEnabled)
        finish?()
        #expect(!overlay.isParked)
    }

    @Test(arguments: [true, false])
    func togglingCornersUpdatesPreferenceAndOverlayWithoutEnablingIt(overlayEnabled: Bool) {
        let (sut, prefs, overlay) = makeSUT(overlayEnabled: overlayEnabled)
        sut.toggleRoundedCorners()
        #expect(!prefs.roundedCornersEnabled)
        #expect(!overlay.roundedCornersEnabled)
        #expect(overlay.isEnabled == overlayEnabled)
        #expect(!sut.isRoundedCornersEnabled)
        if overlayEnabled {
            #expect(factory.made.count == 1)
            #expect(!factory.made[0].roundedCornersEnabled)
            #expect(factory.made[0].isShown)
        } else {
            #expect(factory.made.isEmpty)
        }
        sut.toggleRoundedCorners()
        #expect(prefs.roundedCornersEnabled)
        #expect(overlay.roundedCornersEnabled)
        #expect(sut.isRoundedCornersEnabled)
        if overlayEnabled {
            #expect(factory.made.count == 1)
            #expect(factory.made[0].roundedCornersEnabled)
        }
    }

    @Test func togglingScreensWithoutNotchUpdatesPreferenceOverlayAndState() {
        let (sut, prefs, overlay) = makeSUT()
        screens.list = [Screens.notched, Screens.external]
        sut.toggleScreensWithoutNotch()
        #expect(prefs.screensWithoutNotchEnabled)
        #expect(overlay.windows.count == 2)
        #expect(sut.isScreensWithoutNotchEnabled)
    }

    @Test func hidingIconKeepsOverlayEnabledAndReopeningRestoresAccess() {
        let (sut, prefs, overlay) = makeSUT()
        sut.install()
        defer {
            if let item = sut.statusItem { NSStatusBar.system.removeStatusItem(item) }
        }
        #expect(sut.statusItem?.isVisible == true)
        sut.toggleMenuBarIcon()
        #expect(confirm.calls == 1)
        #expect(!prefs.showMenuBarIcon)
        #expect(sut.statusItem?.isVisible == false)
        #expect(!sut.isMenuBarIconShown)
        #expect(overlay.isEnabled)

        sut.restoreMenuBarIcon()
        #expect(prefs.showMenuBarIcon)
        #expect(sut.statusItem?.isVisible == true)
        #expect(sut.isMenuBarIconShown)
    }

    @Test func installingHonorsHiddenIconPreference() {
        let (sut, prefs, _) = makeSUT()
        prefs.showMenuBarIcon = false
        sut.install()
        defer {
            if let item = sut.statusItem { NSStatusBar.system.removeStatusItem(item) }
        }
        #expect(sut.statusItem?.isVisible == false)
        #expect(!sut.isMenuBarIconShown)
    }

    @Test func stateReflectsDisabledPreference() {
        let (sut, _, overlay) = makeSUT(overlayEnabled: false)
        #expect(!sut.isOverlayEnabled)
        #expect(overlay.windows.isEmpty)
    }

    @Test func toggleOverlayUpdatesPreferenceOverlayAndState() {
        let (sut, prefs, overlay) = makeSUT()
        #expect(sut.isOverlayEnabled)
        sut.toggleOverlay()
        #expect(!prefs.overlayEnabled)
        #expect(!overlay.isEnabled)
        #expect(overlay.windows.isEmpty)
        #expect(!sut.isOverlayEnabled)
        #expect(confirm.calls == 0)
    }

    @Test func systemBackgroundDisablesOverlayAndPersistsState() {
        let (sut, prefs, overlay) = makeSUT()
        prefs.showMenuBarIcon = false
        factory.made[0].delaysHide = true
        sut.disableOverlayForSystemBackground()
        #expect(!factory.made[0].isShown)
        #expect(prefs.showMenuBarIcon)
        #expect(sut.isMenuBarIconShown)
        #expect(backgroundAlert.calls == 1)
        sut.disableOverlayForSystemBackground()
        #expect(backgroundAlert.calls == 1)
        #expect(!prefs.overlayEnabled)
        #expect(!overlay.isEnabled)
        #expect(overlay.windows.isEmpty)
        #expect(!sut.isOverlayEnabled)
        #expect(confirm.calls == 0)
    }

    @Test func cancelHidingIconRestoresAccess() {
        let (sut, prefs, overlay) = makeSUT()
        confirm.answer = false
        sut.toggleMenuBarIcon()
        #expect(confirm.calls == 1)
        #expect(prefs.showMenuBarIcon)
        #expect(sut.isMenuBarIconShown)
        #expect(overlay.isEnabled)
    }

    @Test func enablingOverlayTurnsOnWithoutDialog() {
        let (sut, prefs, overlay) = makeSUT(overlayEnabled: false)
        sut.toggleOverlay()
        #expect(confirm.calls == 0)
        #expect(prefs.overlayEnabled)
        #expect(overlay.windows.count == 1)
        #expect(sut.isOverlayEnabled)
    }

    @Test func toggleLoginItemEnables() {
        let (sut, _, _) = makeSUT()
        sut.toggleLoginItem()
        #expect(login.state == .enabled)
        #expect(sut.isLaunchAtLoginEnabled)
        #expect(sut.launchAtLoginTitle == L10n.launchAtLogin)
    }

    @Test func loginItemFailureIsShown() {
        let (sut, _, _) = makeSUT()
        login.shouldFail = true
        sut.toggleLoginItem()
        #expect(login.state == .disabled)
        #expect(!sut.isLaunchAtLoginEnabled)
        #expect(sut.launchAtLoginTitle == L10n.launchAtLoginFailed)
    }

    @Test func loginItemSuccessClearsFailure() {
        let (sut, _, _) = makeSUT()
        login.shouldFail = true
        sut.toggleLoginItem()
        login.shouldFail = false
        sut.toggleLoginItem()
        #expect(sut.launchAtLoginTitle == L10n.launchAtLogin)
        #expect(sut.isLaunchAtLoginEnabled)
    }

    @Test func openingPopoverResyncsExternalChanges() {
        let (sut, _, _) = makeSUT()
        login.state = .enabled  // The user changed the login item in System Settings.
        sut.popoverWillShow(Notification(name: NSPopover.willShowNotification))
        #expect(sut.isLaunchAtLoginEnabled)
    }

    @Test func loginItemPendingApprovalIsShown() {
        let (sut, _, _) = makeSUT()
        login.stateAfterEnable = .requiresApproval
        sut.toggleLoginItem()
        #expect(sut.launchAtLoginTitle == L10n.launchAtLoginNeedsApproval)
        #expect(!sut.isLaunchAtLoginEnabled)
    }

    @Test func clickingWhilePendingOpensSettings() {
        let (sut, _, _) = makeSUT()
        login.state = .requiresApproval
        sut.toggleLoginItem()
        #expect(login.openedSettings == 1)
        #expect(login.state == .requiresApproval)
    }

    @Test func openingPopoverShowsPendingApproval() {
        let (sut, _, _) = makeSUT()
        login.state = .requiresApproval
        sut.popoverWillShow(Notification(name: NSPopover.willShowNotification))
        #expect(sut.launchAtLoginTitle == L10n.launchAtLoginNeedsApproval)
    }

    @Test(arguments: ["/Applications/HideNotch.app", "/Users/me/Applications/HideNotch.app"])
    func firstLaunchFromApplicationsEnablesLoginItemOnce(bundlePath: String) {
        let (sut, _, _) = makeSUT()
        sut.enableLoginItemOnFirstLaunch(bundlePath: bundlePath, home: "/Users/me")
        #expect(login.state == .enabled)
        #expect(sut.isLaunchAtLoginEnabled)

        sut.toggleLoginItem()  // The user turns it off again.
        sut.enableLoginItemOnFirstLaunch(bundlePath: bundlePath, home: "/Users/me")
        #expect(login.state == .disabled)
    }

    @Test func launchOutsideApplicationsLeavesLoginItemForLater() {
        let (sut, prefs, _) = makeSUT()
        sut.enableLoginItemOnFirstLaunch(
            bundlePath: "/private/var/folders/xy/T/AppTranslocation/ABC/d/HideNotch.app", home: "/Users/me")
        #expect(login.state == .disabled)
        #expect(!prefs.didSetUpLoginItem)
    }
}

import AppKit
import WebKit
import XCTest
@testable import Search

/// Background pins can release their pages while keeping their place in the row.
@MainActor
final class PinSleepTests: XCTestCase {
    private var browser: Browser!
    private let site = "https://pinned.example"
    private var notifying: String { SiteNotifications.key(site) }
    private var wasSleeping = true
    private var wasNotifying = false
    private var wasKeepingAwake = false
    private var awakeSites: Set<String> = []

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func setUp() {
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        wasSleeping = browser.prefs.sleepsTabs
        wasNotifying = browser.prefs.siteNotifications
        wasKeepingAwake = browser.prefs.keepsSitesAwake
        awakeSites = browser.prefs.awakeSites
        browser.prefs.sleepsTabs = true
        browser.prefs.siteNotifications = true
        browser.prefs.keepsSitesAwake = false
        Store.settings.removeObject(forKey: notifying)
    }

    override func tearDown() {
        Store.settings.removeObject(forKey: notifying)
        browser.prefs.sleepsTabs = wasSleeping
        browser.prefs.siteNotifications = wasNotifying
        browser.prefs.keepsSitesAwake = wasKeepingAwake
        browser.prefs.awakeSites = awakeSites
        browser.parked = [:]
        browser.closeAll()
        browser = nil
    }

    /// A pinned tab with its page made, last looked at long ago.
    private func pin(_ url: String) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration)
        tab.setAddressOptimistically(URL(string: url)!)
        _ = tab.web
        tab.pin = "P"
        tab.touch(at: .distantPast)
        return tab
    }

    private func park(_ tabs: [Tab]) {
        browser.parked[UUID()] = Parked(tabs: tabs, active: nil)
    }

    private func insert(_ tab: Tab) {
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
    }

    private func waitForSleep(_ tab: Tab) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !tab.asleep, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(tab.asleep)
    }

    func testAnIdlePinInTheCurrentSpaceSleepsAndWakesWhenSelected() async throws {
        let here = pin(site + "/article")
        let home = try XCTUnwrap(URL(string: site))
        here.home = home
        insert(here)
        let row = browser.tabs.map(\.id)
        let page = here.address
        XCTAssertNil(browser.awake(because: here))

        browser.sleepIdle()
        try await waitForSleep(here)
        XCTAssertNil(here.built)
        XCTAssertEqual(browser.tabs.map(\.id), row)
        XCTAssertEqual(here.pin, "P")
        XCTAssertEqual(here.home, home)
        XCTAssertEqual(here.address, page)

        browser.select(here)
        XCTAssertFalse(here.asleep)
        XCTAssertNotNil(here.built)
        XCTAssertEqual(browser.activeID, here.id)
        XCTAssertEqual(browser.awake(because: here, manually: true), "on screen")
    }

    func testPinInAnotherSpaceMaySleep() {
        let away = pin(site)
        park([away])
        XCTAssertNil(browser.awake(because: away), "Nothing should keep a parked pin awake")
    }

    func testPinWhoseSiteMayNotifyStaysAwake() {
        let away = pin(site + "/inbox")
        park([away])
        Store.settings.set(true, forKey: notifying)
        XCTAssertTrue(browser.mayNotify(away))
        XCTAssertNotNil(browser.awake(because: away))
        // Answered no, or notifications off in Settings: it may sleep.
        Store.settings.set(false, forKey: notifying)
        XCTAssertNil(browser.awake(because: away))
        Store.settings.set(true, forKey: notifying)
        browser.prefs.siteNotifications = false
        XCTAssertFalse(browser.mayNotify(away))
        XCTAssertNil(browser.awake(because: away))
    }

    func testNotificationPinInTheCurrentSpaceCanBeSleptManually() async {
        let here = pin(site)
        insert(here)
        Store.settings.set(true, forKey: notifying)
        XCTAssertNotNil(browser.awake(because: here))
        XCTAssertNil(browser.awake(because: here, manually: true))

        let result = await withCheckedContinuation { continuation in
            browser.sleep(here, manually: true) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(result, "asleep")
        XCTAssertNil(here.built)
    }

    func testExplicitKeepAwakeSiteProtectsPinFromManualSleep() {
        let here = pin(site)
        insert(here)
        browser.prefs.keepsSitesAwake = true
        browser.keepAwake(true, for: here)
        XCTAssertEqual(browser.awake(because: here, manually: true), "kept awake for this site")
    }

    func testAnotherSitesPermissionDoesNotCount() {
        Store.settings.set(true, forKey: notifying)
        let other = pin("https://elsewhere.example")
        park([other])
        XCTAssertNil(browser.awake(because: other))
        let port = pin("https://pinned.example:8443")
        park([port])
        XCTAssertNil(browser.awake(because: port), "Another port is another origin")
    }

    func testParkedPinStillKeptAwakeByWhatItIsDoing() {
        let away = pin(site)
        away.noisy = true
        park([away])
        XCTAssertEqual(browser.awake(because: away), "playing sound")
    }

    func testAParkedPinGoesToSleep() async throws {
        let away = pin(site)
        _ = away.web
        park([away])
        let said = await withCheckedContinuation { continuation in
            browser.sleep(away) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(said, "asleep")
        XCTAssertTrue(away.asleep)
    }

    func testOverflowSleepsTheOldestEligibleBackgroundTab() async throws {
        let tabs = (0..<10).map { pin(site + "/\($0)") }
        let now = Date()
        for (index, tab) in tabs.enumerated() {
            tab.touch(at: now.addingTimeInterval(Double(index - tabs.count)))
            insert(tab)
        }
        tabs[0].noisy = true

        browser.sleepIdle()
        try await waitForSleep(tabs[1])
        XCTAssertNil(tabs[1].built)
        XCTAssertTrue(tabs.enumerated().filter { $0.offset != 1 }.allSatisfy { $0.element.built != nil })
    }

    func testNeverPreventsPressureSleepButAllowsManualSleep() async throws {
        let here = pin(site)
        insert(here)
        browser.prefs.sleepsTabs = false

        browser.sleepIdle(within: 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(here.built)
        let result = await withCheckedContinuation { continuation in
            browser.sleep(here, manually: true) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(result, "asleep")
    }
}

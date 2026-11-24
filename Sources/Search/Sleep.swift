import AppKit
import WebKit

// Tabs you aren't using, put to sleep.
//
// A page open in a tab keeps its whole content process — a hundred to three
// hundred megabytes, running its timers, holding its sockets — for as long as
// the tab exists. Twenty tabs is two or three gigabytes spent on the nineteen
// nobody is looking at. So a tab left alone for half an hour gives its page
// back, and keeps what it takes to come back exactly where it was: its
// history, its scroll position, and a picture to show while the page is
// rebuilt underneath (see Tab.sleep).
//
// The pages on screen and tabs playing sound, on a call, downloading, or
// holding a draft stay awake. Pins follow the same idle rules as other
// tabs, with an automatic exception for sites allowed to send notifications.
// Sleep leaves a pin in place at its current address.
//
// With the last window closed and the app still running, there is nothing
// on screen to wait for: the tabs the same rules let go sleep at once (see
// sleepShut), and the ones on screen wake when the window comes back.
//
// Half an hour is Normal. Settings › Tabs › How soon tabs sleep makes it
// two hours (Later) or ten minutes (Sooner).
//
// In Low Power Mode, with Settings › General › Save power in Low Power Mode
// turned on, the wait is never longer than Sooner's ten minutes: a page asleep
// runs no timers and wakes no processor. A Mac that is only hot keeps the pace
// chosen. The look reads the wait each time, so it follows the switch at once.
//
// Each window tries to keep at most eight eligible background pages loaded.
// When macOS says memory is short, the idle wait shrinks to at most five
// minutes on a warning and to nothing when it is critical.

/// How soon tabs sleep, as chosen in Settings. Three levels rather than
/// numbers: what someone decides is how much a waking tab bothers them, not
/// how many minutes.
enum SleepPace: String, CaseIterable, Identifiable {
    case later, normal, sooner

    nonisolated static let key = "tabs.sleep.pace"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .later: return "Later"
        case .normal: return "Normal"
        case .sooner: return "Sooner"
        }
    }

    /// Away this long, a tab sleeps.
    var wait: TimeInterval {
        switch self {
        case .later: return 2 * 60 * 60
        case .normal: return 30 * 60
        case .sooner: return 10 * 60
        }
    }

    /// What the line in Settings says under the choice.
    var detail: String {
        switch self {
        case .later: return "After two hours away."
        case .normal: return "After half an hour away."
        case .sooner: return "After ten minutes away."
        }
    }

    /// The one chosen, Normal until someone chooses.
    nonisolated static var chosen: SleepPace {
        Store.settings.string(forKey: key).flatMap(SleepPace.init) ?? .normal
    }
}

extension Browser {
    private static let backgroundPageLimit = 8

    /// How long a tab has to go without being looked at: the chosen pace's
    /// wait, no longer than Sooner's in Low Power Mode when the switch for it
    /// is on, or `sleep.after` in seconds, for the bench and the measurements.
    static var sleepAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.after")
        if set > 0 { return set }
        let wait = SleepPace.chosen.wait
        return Motion.savingPower ? min(wait, SleepPace.sooner.wait) : wait
    }

    /// Started once, at launch. The same look closes the tabs left alone
    /// longest, when tabs close themselves (see Closing.swift).
    func watchForSleep() {
        let every = min(60, max(5, Browser.sleepAfter / 4))
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleepIdle()
                self?.closeLeftAlone()
            }
        }
        timer.tolerance = every / 4
        RunLoop.main.add(timer, forMode: .common)
        dozing = timer

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.pressure?.data else { return }
                self.sleepIdle(within: event.contains(.critical) ? 0 : min(Browser.sleepAfter, 5 * 60))
            }
        }
        source.resume()
        pressure = source
    }

    /// Oldest pages first, including the other spaces. A pressure request can
    /// replace a routine sweep after the current tab finishes.
    func sleepIdle(within given: TimeInterval? = nil) {
        guard prefs.sleepsTabs, !retired else { return }
        if sleepSweepRunning {
            if let given { pendingSleepWait = min(pendingSleepWait ?? given, given) }
            return
        }
        let wait = given ?? Browser.sleepAfter
        let eligible = (tabs + parkedTabs)
            .filter { awake(because: $0) == nil }
            .sorted { $0.touched < $1.touched }
        var excess = max(0, eligible.count - Browser.backgroundPageLimit)
        var rest = eligible.map { (tab: $0, touched: $0.touched) }[...]
        sleepSweepRunning = true
        func next() {
            if let urgent = pendingSleepWait {
                pendingSleepWait = nil
                sleepSweepRunning = false
                sleepIdle(within: urgent)
                return
            }
            while prefs.sleepsTabs, !retired, let entry = rest.popFirst() {
                let overLimit = excess > 0
                guard entry.tab.touched == entry.touched,
                      overLimit || Date().timeIntervalSince(entry.touched) >= wait else { continue }
                // Skip the Retina snapshot when making room for other tabs.
                sleep(entry.tab, preview: given == nil && !overLimit, automatic: true) { result in
                    if overLimit, result == "asleep" { excess -= 1 }
                    DispatchQueue.main.async { next() }
                }
                return
            }
            sleepSweepRunning = false
        }
        next()
    }

    /// The last window closed with the app running (Browsers.closing):
    /// nothing is on screen any more, so every tab the rules here let go
    /// sleeps now. The tabs stay, with their history and place, for
    /// the window that comes back (see `shut`). One playing sound, on a
    /// call, downloading, with its video out or holding something typed
    /// stays awake, as it would at any other time. A page still loading is
    /// looked at once more a little later.
    func sleepShut(again: Bool = true) {
        guard prefs.sleepsTabs, shut else { return }
        let loading = (tabs + parkedTabs).contains { awake(because: $0) == "still loading" }
        sleepIdle(within: 0)
        guard again, loading else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.sleepShut(again: false) }
    }

    /// The window back after `sleepShut`: the tabs it shows wake, the others
    /// wait to be looked at, as after a launch.
    func wakeShown() {
        for tab in tabs where visibleTabIDs.contains(tab.id) { _ = tab.wake() }
    }

    /// Why a tab has to stay awake — nil when nothing keeps it. The clock is
    /// the caller's business; this is everything else.
    func awake(because tab: Tab, manually: Bool = false) -> String? {
        // With the last window closed (`shut`) nothing is on screen.
        if !shut, visibleTabIDs.contains(tab.id) { return "on screen" }
        if tab.bench { return "a bench tab" }
        if tab.isBlank { return "blank" }
        if tab.asleep { return "already asleep" }
        guard tab.address != nil, tab.built != nil else { return "no page" }
        if tab.loading || tab.built?.isLoading == true { return "still loading" }
        if !manually, tab.pin != nil, mayNotify(tab) { return "pinned, and its site may send notifications" }
        return busy(tab)
    }

    func keepsAwake(_ tab: Tab) -> Bool {
        guard prefs.keepsSitesAwake, let host = tab.awakeHost else { return false }
        return (tab.shy ? tab.awakeSites : prefs.awakeSites).contains(host)
    }

    func keepAwake(_ on: Bool, for tab: Tab) {
        guard let host = tab.awakeHost else { return }
        if tab.shy {
            if on { tab.awakeSites.insert(host) } else { tab.awakeSites.remove(host) }
        } else {
            if on { prefs.awakeSites.insert(host) } else { prefs.awakeSites.remove(host) }
        }
    }

    /// Whether the site on the tab is allowed to send notifications (see
    /// Notifications.swift): answered yes, with notifications on in Settings.
    func mayNotify(_ tab: Tab) -> Bool {
        guard prefs.siteNotifications, !tab.shy, let url = tab.address,
              let scheme = url.scheme, let host = url.host(), !host.isEmpty else { return false }
        let site = Browser.origin(scheme, host, url.port ?? 0)
        return Store.settings.object(forKey: SiteNotifications.key(site)) as? Bool == true
    }

    /// What the page is in the middle of that letting it go would cut off:
    /// the part of staying awake that closing a tab asks too (Closing.swift).
    func busy(_ tab: Tab) -> String? {
        if DevToolsPackages.busy(tab) { return "a developer tool is open" }
        if keepsAwake(tab) { return "kept awake for this site" }
        if tab.noisy { return "playing sound" }
        if tab.floating || floating == tab.id || pictured == tab.id { return "its video is out" }
        if let web = tab.built {
            if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return "on a call" }
            if #available(macOS 15.4, *), ExtensionCapture.screen(web) { return "recording the screen" }
            if downloading.contains(where: { $0.webView === web }) { return "downloading" }
        }
        if heldDialogs[tab.id]?.isEmpty == false || paneQuestions.contains(where: { $0.tab == tab.id }) {
            return "a question waiting"
        }
        // A sign-in window hands its answer back to the page that opened it.
        if let pair = activeSplit {
            if tabs.contains(where: { pair.contains($0.id) && $0.opener == tab.id }) {
                return "the page on screen came from it"
            }
        } else if active?.opener == tab.id {
            return "the page on screen came from it"
        }
        return nil
    }

    /// Sleep the chosen background tabs one at a time.
    func sleepManually(_ tabs: [Tab]) {
        let single = tabs.count == 1
        var rest = tabs[...]
        func next() {
            guard let tab = rest.popFirst() else { return }
            sleep(tab, manually: true, preview: single) { result in
                if single {
                    self.announce(result == "asleep" ? "Tab asleep" : "Stays awake: \(result)")
                } else {
                    DispatchQueue.main.async { next() }
                }
            }
        }
        next()
    }

    /// Check the page and its drafts again after each WebKit reply. A slow
    /// page gets to stay awake while the sweep moves on to the next one.
    func sleep(_ tab: Tab, manually: Bool = false, preview: Bool = true, automatic: Bool = false,
               done: ((String) -> Void)? = nil) {
        if let reason = awake(because: tab, manually: manually) {
            done?(reason)
            return
        }
        let id = tab.id
        guard sleepingTabs.insert(id).inserted else { done?("already going to sleep"); return }
        let web = tab.built.map(ObjectIdentifier.init), document = tab.documentGeneration, touched = tab.touched
        var finished = false
        var completion = done
        let finish: (String) -> Void = { [weak self] result in
            guard !finished else { return }
            finished = true
            self?.sleepingTabs.remove(id)
            let callback = completion
            completion = nil
            callback?(result)
        }
        func check(_ browser: Browser, _ tab: Tab, typed: Bool = false) -> Bool {
            guard !finished else { return false }
            if browser.retired || !(browser.tabs.contains { $0 === tab } ||
                browser.parked.values.contains { $0.tabs.contains { $0 === tab } }) {
                finish("gone")
            } else if automatic, !browser.prefs.sleepsTabs {
                finish("automatic sleep is off")
            } else if tab.built.map(ObjectIdentifier.init) != web || tab.documentGeneration != document ||
                        tab.touched != touched {
                finish("page changed")
            } else if typed {
                finish("holding something typed")
            } else if let reason = browser.awake(because: tab, manually: manually) {
                finish(reason)
            }
            return !finished
        }
        tab.unsaved { [weak self, weak tab] typed in
            guard let self, let tab else { finish("gone"); return }
            guard check(self, tab, typed: typed) else { return }
            let save: (Data?) -> Void = { [weak self, weak tab] picture in
                guard let self, let tab else { finish("gone"); return }
                guard check(self, tab) else { return }
                KeptSession.capture(tab) { [weak self, weak tab] storage in
                    guard let self, let tab else { finish("gone"); return }
                    guard check(self, tab) else { return }
                    // A draft may have appeared while WebKit pictured the page or read storage.
                    tab.unsaved { [weak self, weak tab] typed in
                        guard let self, let tab else { finish("gone"); return }
                        guard check(self, tab, typed: typed) else { return }
                        tab.sleep(picture: picture, session: storage)
                        finish("asleep")
                    }
                }
            }
            if preview { tab.snapshot(save) } else { save(nil) }
        }
        if !finished {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish("the page did not respond") }
        }
    }
}

// A tab keeps its sessionStorage through sleep.
//
// A sleeping tab's history and scroll come back with its view
// (`interactionState`), but the view made to wake it starts a new browsing
// session, and sessionStorage goes with the old one. Some sites keep a draft,
// a form half filled or a step of a checkout only there, so waking lost it.
// WebKit has no way to hand sessionStorage from one view to the next (nothing
// on WKWebView or its data store), so the page's own is read as it falls
// asleep and written back as it wakes, before any of its scripts run.
//
// The page itself only: frames inside it lose theirs, as before. Not for a
// private tab, so nothing of one is held after its view goes. Not past
// `cap`: sleep is there to give memory back. Held in memory only, never in
// the session file, and only until the woken page commits; a later page in
// the same tab never gets it, so nothing the page cleared since comes back.
// Read and written in Search's world, where a page can't stand in for the
// functions used, and storage is the same in every world.
@MainActor
enum KeptSession {
    /// Past this, a page's storage isn't kept: about half a megabyte.
    static let cap = 512 * 1024

    private static let read = """
        (() => {
          try {
            const s = sessionStorage;
            if (!s.length) return null;
            const items = [];
            let length = 0;
            for (let i = 0; i < s.length; i++) {
              const k = s.key(i), v = s.getItem(k);
              length += k.length + v.length;
              if (length > \(cap)) return null;
              items.push([k, v]);
            }
            return JSON.stringify([location.origin, items]);
          } catch (e) { return null; }
        })()
        """

    /// Read the current page before its view goes. A page that doesn't answer keeps nothing.
    static func capture(_ tab: Tab, then: @escaping (String?) -> Void) {
        guard !tab.shy, let web = tab.built else { return then(nil) }
        web.evaluateJavaScript(read, in: nil, in: Web.world) { result in
            let json = (try? result.get()) as? String
            then(json.flatMap { $0.utf8.count <= cap ? $0 : nil })
        }
    }

    /// For the woken tab's next document (Tab.arm), ahead of its scripts:
    /// only for the same origin, and only into a session that's still empty.
    static func script(for tab: Tab) -> String? {
        guard let json = tab.sleepingSession else { return nil }
        return """
            (() => {
              try {
                const [origin, items] = \(json);
                if (location.origin !== origin || sessionStorage.length) return;
                for (const [k, v] of items) sessionStorage.setItem(k, v);
              } catch (e) {}
            })();
            """
    }

    /// The woken page committed (Tab.didCommit): its copy goes, and the
    /// answer says the tab should arm again without it. A blank page on the
    /// way there doesn't count.
    static func committed(_ tab: Tab) -> Bool {
        guard tab.sleepingSession != nil, let url = tab.built?.url, url.absoluteString != "about:blank" else { return false }
        tab.sleepingSession = nil
        return true
    }
}

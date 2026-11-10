import Testing
@testable import CortexKit

/// `#expect` cannot call a mutating method directly.
private final class Probe {
    private var watchdog = TunnelWatchdog()
    func replaces(running: Bool, ready: Bool, online: Bool) -> Bool {
        watchdog.shouldReplace(running: running, ready: ready, online: online)
    }
}

@Test func healthyTunnelIsLeftAlone() {
    let watchdog = Probe()
    for _ in 0..<100 { #expect(!watchdog.replaces(running: true, ready: true, online: true)) }
}

@Test func stalledTunnelIsReplacedAfterFiveMinutes() {
    let watchdog = Probe()
    for _ in 1..<TunnelWatchdog.checksBeforeReplacingStalled {
        #expect(!watchdog.replaces(running: true, ready: false, online: true))
    }
    #expect(watchdog.replaces(running: true, ready: false, online: true))
    #expect(!watchdog.replaces(running: true, ready: false, online: true)) // the count starts over
}

@Test func nothingIsReplacedWhileOffline() {
    let watchdog = Probe()
    for _ in 0..<100 {
        #expect(!watchdog.replaces(running: true, ready: false, online: false))
        #expect(!watchdog.replaces(running: false, ready: false, online: false))
    }
}

@Test func recoveringOrGoingOfflineResetsTheCount() {
    for interruption in [(ready: true, online: true), (ready: false, online: false)] {
        let watchdog = Probe()
        for _ in 1..<TunnelWatchdog.checksBeforeReplacingStalled {
            #expect(!watchdog.replaces(running: true, ready: false, online: true))
        }
        #expect(!watchdog.replaces(running: true, ready: interruption.ready, online: interruption.online))
        #expect(!watchdog.replaces(running: true, ready: false, online: true))
    }
}

@Test func exitedTunnelIsReplacedSoonerAndRetriedAtAMeasuredPace() {
    let watchdog = Probe()
    #expect(!watchdog.replaces(running: false, ready: false, online: true))
    #expect(watchdog.replaces(running: false, ready: false, online: true))
    #expect(!watchdog.replaces(running: false, ready: false, online: true))
    #expect(watchdog.replaces(running: false, ready: false, online: true))
}

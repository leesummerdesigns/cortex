import Foundation

/// Decides when the Bridge's Cloudflare tunnel is dead and needs replacing.
///
/// A new tunnel gets a new public address, which breaks every connector until it is added again, so a tunnel
/// that may still recover is left alone: nothing counts while the Mac is offline, and cloudflared gets
/// five minutes to reconnect by itself. A tunnel whose process has exited cannot recover and is replaced sooner.
public struct TunnelWatchdog {
    public static let interval = Duration.seconds(30)
    static let checksBeforeReplacingStalled = 10
    static let checksBeforeReplacingExited = 2

    private var failures = 0

    public init() {}

    /// Call once per `interval`. Returns true when the tunnel should be replaced now.
    public mutating func shouldReplace(running: Bool, ready: Bool, online: Bool) -> Bool {
        guard online, !(running && ready) else {
            failures = 0
            return false
        }
        failures += 1
        guard failures >= (running ? Self.checksBeforeReplacingStalled : Self.checksBeforeReplacingExited) else {
            return false
        }
        failures = 0
        return true
    }
}

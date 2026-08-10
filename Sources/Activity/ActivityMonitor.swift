import Foundation

/// A single question the machine can answer about itself.
///
/// Probes are opened when the panel opens and closed when it closes. Between
/// those two calls a probe may hold a mach port, a subscription, a cached
/// counter; after `close()` it must hold none of them. That contract is the
/// entire reason Taurine can promise the panel costs nothing while it is shut.
///
/// `read` is handed the sample under construction and fills in its own slice.
/// Probes run in the order the monitor was given them, which lets a probe that
/// enriches an earlier one (frequencies onto clusters) simply come later in the
/// list. A probe that cannot answer leaves its slice alone rather than writing
/// a zero.
protocol ActivityProbe: AnyObject {

    /// Short name, used in diagnostics when a probe declines to open.
    var name: String { get }

    /// Acquire whatever the probe needs. Throwing here drops just this probe;
    /// the rest of the panel carries on without it.
    func open() throws

    /// Release everything. Called on every panel close, and safe to call twice.
    func close()

    /// Fill this probe's part of the sample. Called on the sampling queue.
    func read(into sample: inout ActivitySample)
}

/// The metronome. ⏱️
///
/// Owns the only repeating timer Taurine ever creates, and owns it only while
/// somebody is looking. `start` opens the probes and begins sampling; `stop`
/// cancels the timer, closes every probe and forgets them. There is no
/// "paused" state, no warm cache and no background refresh, because the whole
/// claim on the menu badge (`0 timers`) has to survive somebody checking it.
///
/// Sampling happens on a utility queue: reading IOReport takes single-digit
/// milliseconds and the main thread is busy drawing. Samples are delivered back
/// on the main queue, already complete.
final class ActivityMonitor {

    /// Delivered on the main queue, once per interval.
    var onSample: ((ActivitySample) -> Void)?

    /// Probes that refused to open, in the order they were tried. Shown in the
    /// panel's footer so a missing tile has a stated reason.
    private(set) var unavailable: [(name: String, reason: String)] = []

    private let probes: [ActivityProbe]
    private let queue = DispatchQueue(label: "io.github.john-athan.taurine.activity", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var open: [ActivityProbe] = []
    private var lastUptime: TimeInterval?

    init(probes: [ActivityProbe]) {
        self.probes = probes
    }

    var isRunning: Bool { timer != nil }

    /// Begin sampling every `interval` seconds. The first sample is taken
    /// immediately and carries `interval == 0`, which tells rate probes they
    /// have no baseline yet.
    func start(interval: TimeInterval) {
        guard timer == nil else { return }

        queue.sync {
            unavailable = []
            open = probes.compactMap { probe in
                do {
                    try probe.open()
                    return probe
                } catch {
                    unavailable.append((probe.name, "\(error)"))
                    return nil
                }
            }
            lastUptime = nil
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        // A tenth of the interval of leeway lets the kernel coalesce our wakeup
        // with one it was going to make anyway.
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    /// Stop sampling and give everything back.
    func stop() {
        guard let t = timer else { return }
        timer = nil
        t.cancel()
        queue.sync {
            for probe in open { probe.close() }
            open = []
            lastUptime = nil
        }
    }

    deinit { stop() }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastUptime.map { now - $0 } ?? 0
        lastUptime = now

        var sample = ActivitySample(uptime: now, interval: max(0, elapsed))
        for probe in open { probe.read(into: &sample) }

        DispatchQueue.main.async { [weak self] in self?.onSample?(sample) }
    }
}

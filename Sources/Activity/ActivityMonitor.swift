import Foundation

/// A single question the machine can answer about itself.
///
/// Probes are opened when the panel opens and closed when it closes. Between
/// those two calls a probe may hold a mach port, a subscription, a cached
/// counter; after `close()` it must hold none of them. That contract is the
/// entire reason Taurine can promise the panel costs nothing while it is shut.
///
/// `read` is handed the sample under construction and fills in its own slice.
/// A probe that cannot answer leaves its slice alone rather than writing a zero.
///
/// Some probes only have something to say about what another probe already
/// wrote: the energy probe puts frequencies onto the clusters the processor
/// probe built, and writes nothing at all if they are not there yet. That used
/// to be a matter of list order, which is a dependency nothing enforces and
/// nothing notices breaking: reorder the list and the panel quietly loses every
/// clock reading while every test still passes. So a probe declares its `stage`
/// instead, and the monitor runs every measurer before any enricher whatever
/// order it was handed.
///
/// Anything that measures a rate takes its baseline reading in `open()`, not on
/// its first `read`. The difference is what the user sees: a panel whose first
/// frame is blank looks broken, and a panel that has to wait a full second
/// before it says anything feels slow. Opening the probes is the moment the
/// clock starts, so the first frame can arrive a quarter of a second later with
/// real numbers in it.
protocol ActivityProbe: AnyObject {

    /// Short name, used in diagnostics when a probe declines to open.
    var name: String { get }

    /// Whether this probe produces a section of the sample or decorates one
    /// somebody else produced. Measuring is the default, so only the unusual
    /// case has to say anything.
    var stage: ProbeStage { get }

    /// Acquire whatever the probe needs, and take the first reading of any
    /// counter this probe measures the change in. Throwing here drops just this
    /// probe; the rest of the panel carries on without it.
    func open() throws

    /// Release everything. Called on every panel close, and safe to call twice.
    func close()

    /// Fill this probe's part of the sample. Called on the sampling queue.
    func read(into sample: inout ActivitySample)
}

/// When a probe wants to run, relative to the others.
enum ProbeStage {
    /// Writes a section of the sample from nothing. Runs first.
    case measure
    /// Adds to a section another probe has already written, and does nothing
    /// useful if that section is absent. Runs after every measurer.
    case enrich
}

extension ActivityProbe {
    var stage: ProbeStage { .measure }
}

/// The metronome. ⏱️
///
/// Owns one repeating timer, and owns it only while somebody is looking.
/// `start` opens the probes and begins sampling; `stop` cancels the timer,
/// closes every probe and forgets them. There is no "paused" state, no warm
/// cache and no background refresh, which is what lets the panel print its own
/// receipt and mean it.
///
/// It is not the app's only timer, and the panel's receipt is careful to say
/// "this panel" for that reason: a countdown intent runs one while it counts,
/// and a toast runs one for the length of its animation. What is true is that
/// nothing here runs while the panel is shut.
///
/// Sampling happens on a utility queue: reading IOReport takes single-digit
/// milliseconds and the main thread is busy drawing. Samples are delivered back
/// on the main queue, already complete.
final class ActivityMonitor {

    /// Delivered on the main queue, once per interval.
    var onSample: ((ActivitySample) -> Void)?

    private let probes: [ActivityProbe]
    private let queue = DispatchQueue(label: "io.github.john-athan.taurine.activity", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var open: [ActivityProbe] = []
    private var unavailable: [ProbeFailure] = []
    private var lastUptime: TimeInterval?

    /// Whether a session is meant to be running. Read and written from the
    /// caller's thread and from the sampling queue, so it is behind a lock:
    /// `queue.async` orders when a block starts, not when a later write on
    /// another thread lands, and Thread Sanitizer says so out loud. The lock is
    /// taken on open, on close and once inside the opening block, never per
    /// sample.
    private let stateLock = NSLock()
    private var runningLocked = false
    private var running: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return runningLocked }
        set { stateLock.lock(); runningLocked = newValue; stateLock.unlock() }
    }

    /// Claim the transition, or report that somebody else already has. One
    /// atomic step, so two threads calling `start` cannot both get past it.
    private func claim(_ wanted: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard runningLocked != wanted else { return false }
        runningLocked = wanted
        return true
    }

    init(probes: [ActivityProbe]) {
        self.probes = probes
    }

    /// True between `start` and `stop`, whatever the sampling queue is doing.
    var isRunning: Bool { running }

    /// Begin sampling every `interval` seconds.
    ///
    /// Opening the probes is what starts the clock, so the first sample comes a
    /// quarter of a second later rather than immediately: long enough to be a
    /// real measurement, short enough that the panel is populated before the
    /// user has finished looking at it. Every sample therefore carries a
    /// positive `interval`, and no probe ever has to describe a state it has no
    /// baseline for.
    ///
    /// Opening is done on the sampling queue, not here. One probe alone takes
    /// the better part of a tenth of a second to enumerate what the chip
    /// publishes, and the caller is a menu item click: the popover has to be on
    /// screen in that time, not after it.
    func start(interval: TimeInterval) {
        guard claim(true) else { return }

        queue.async { [weak self] in
            guard let self, self.running else { return }
            var failures: [ProbeFailure] = []
            let opened = self.probes.compactMap { probe -> ActivityProbe? in
                do {
                    try probe.open()
                    return probe
                } catch {
                    failures.append(ProbeFailure(name: probe.name, reason: "\(error)"))
                    return nil
                }
            }
            // Measurers first, enrichers after, each group in the order it was
            // given. Partitioning rather than sorting, because `sorted` is not
            // stable and the order inside a group is the caller's business.
            self.open = opened.filter { $0.stage == .measure } + opened.filter { $0.stage == .enrich }
            self.unavailable = failures
            self.lastUptime = ProcessInfo.processInfo.systemUptime

            let firstSample = min(0.25, interval)
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            // A tenth of the interval of leeway lets the kernel coalesce our
            // wakeup with one it was going to make anyway.
            t.schedule(deadline: .now() + firstSample, repeating: interval,
                       leeway: .milliseconds(Int(interval * 100)))
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    /// Stop sampling and give everything back. Safe to call from anywhere, at
    /// any point in the opening sequence: the teardown lands on the same serial
    /// queue as the setup, so it cannot overtake it.
    func stop() {
        guard claim(false) else { return }

        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            for probe in self.open { probe.close() }
            self.open = []
            self.unavailable = []
            self.lastUptime = nil
        }
    }

    deinit {
        // Not `stop()`: an async hop that captures a deallocating object is a
        // crash waiting for a slow machine. Whatever is still open is closed
        // here and now, on whichever thread let the last reference go.
        running = false
        timer?.cancel()
        timer = nil
        for probe in open { probe.close() }
        open = []
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        // The baseline was taken in `start`, so there is always a previous
        // instant to measure from. A clamp rather than a guard: a suspended
        // machine can hand back an interval that makes no sense, and dividing
        // by it would be worse than treating it as one tick.
        let elapsed = max(0.001, now - (lastUptime ?? now))
        lastUptime = now

        var sample = ActivitySample(uptime: now, interval: elapsed)
        sample.unavailable = unavailable
        for probe in open { probe.read(into: &sample) }

        DispatchQueue.main.async { [weak self] in self?.onSample?(sample) }
    }
}

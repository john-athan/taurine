import Foundation

/// The narrator. 🗣️
///
/// What VoiceOver says about each tile. A panel made of hand-drawn views has no
/// text for the accessibility system to find: without this file the whole thing
/// is one silent rectangle, and "group" is the only word anybody gets.
///
/// Each function returns one finished sentence rather than a pile of fragments,
/// because VoiceOver reads a value as a single utterance and a fragment like
/// "58" with no unit and no cluster is worse than silence. The sentences are
/// written to be *heard*: units are spelled out, because "8.1 W" is read as
/// "eight point one w", and cluster ids become words, because "P0" is read as
/// "pee zero" and means nothing said aloud.
///
/// The trap: these look like they could be built by stripping symbols out of
/// the drawn strings, and every attempt to do that breaks the moment a unit
/// crosses a magnitude. They share `ActivityFormat`'s arithmetic instead, via
/// its unit parameters, so the spoken number and the drawn number can never
/// disagree about rounding.
enum ActivitySpeech {

    // MARK: - spoken units

    static func watts(_ value: Double) -> String {
        ActivityFormat.watts(value, unit: value == 1 ? "watt" : "watts")
    }

    /// An adapter's rating, in whole watts, like the number printed on it.
    static func rated(_ value: Double) -> String {
        ActivityFormat.wattsRating(value, unit: value == 1 ? "watt" : "watts")
    }

    static func megahertz(_ value: Double) -> String {
        ActivityFormat.megahertz(value, units: ("megahertz", "gigahertz"))
    }

    static func percent(_ fraction: Double) -> String {
        ActivityFormat.percent(fraction, unit: "percent")
    }

    /// "2 hours 47 minutes". Built from the same split the drawn "2 h 47 m"
    /// uses, so the two can never disagree about which minute it is.
    static func duration(_ seconds: TimeInterval) -> String {
        guard let split = ActivityFormat.hoursMinutes(seconds) else { return ActivityFormat.unknown }
        var parts: [String] = []
        if split.hours > 0 {
            parts.append("\(split.hours) \(split.hours == 1 ? "hour" : "hours")")
        }
        if split.minutes > 0 {
            parts.append("\(split.minutes) \(split.minutes == 1 ? "minute" : "minutes")")
        }
        return parts.joined(separator: " ")
    }

    static func bytes(_ value: UInt64) -> String {
        ActivityFormat.bytes(value, units: ActivityFormat.spokenByteUnits)
    }

    static func bytesPerSecond(_ value: Double) -> String {
        ActivityFormat.bytesPerSecond(value, units: ActivityFormat.spokenRateUnits)
    }

    // MARK: - the tiles

    /// What a tile is called out loud. The drawn titles are set in capitals for
    /// the eye, and handed to a reader as written they are either an initialism
    /// somebody has to expand ("CPU") or, once capitalised, a nonsense word
    /// ("Cpu"). The two initialisms become the same words `power` already uses
    /// when it reads the parts out, so the panel calls a thing by one name
    /// whether it is naming a tile or reading one.
    static func tileName(_ title: String) -> String {
        switch title {
        case "CPU": return "Processor"
        case "GPU": return "Graphics"
        default:    return title.capitalized
        }
    }

    /// `E` becomes "efficiency cores", `P1` becomes "performance cluster 1".
    static func clusterName(_ cluster: CPUActivity.Cluster) -> String {
        let kind = cluster.kind == .efficiency ? "efficiency" : "performance"
        let index = cluster.id.dropFirst()
        return index.isEmpty ? "\(kind) cores" : "\(kind) cluster \(index)"
    }

    static func cluster(_ cluster: CPUActivity.Cluster) -> String {
        var line = "\(clusterName(cluster)), \(percent(cluster.busy))"
        if let mhz = cluster.frequencyMHz {
            line += " at \(megahertz(mhz))"
        }
        line += ", \(cluster.cores.count) \(cluster.cores.count == 1 ? "core" : "cores")"
        return line
    }

    static func cpu(_ cpu: CPUActivity) -> String {
        guard !cpu.clusters.isEmpty else { return "no processor data" }
        return ([percent(cpu.busy) + " busy overall"]
                + cpu.clusters.map(cluster)).joined(separator: ". ") + "."
    }

    static func gpu(_ gpu: GPUActivity) -> String {
        var line = "\(percent(gpu.utilization)) busy"
        if let mhz = gpu.frequencyMHz { line += " at \(megahertz(mhz))" }
        return line + "."
    }

    static func power(_ power: PowerActivity) -> String {
        guard let total = power.totalWatts else { return "no power data" }
        var parts: [String] = ["\(watts(total)) total"]
        if let w = power.cpuWatts { parts.append("processor \(watts(w))") }
        if let w = power.gpuWatts { parts.append("graphics \(watts(w))") }
        if let w = power.aneWatts { parts.append("neural engine \(watts(w))") }
        return parts.joined(separator: ", ") + "."
    }

    /// The battery, read as one sentence: how full, which way the energy is
    /// going, how fast, and how long that leaves. The state comes first after
    /// the percentage because it is the thing that changes what the rest of the
    /// sentence means.
    static func battery(_ battery: BatteryActivity) -> String {
        var parts: [String] = ["\(percent(battery.charge)) charged"]
        let flow = battery.batteryWatts.map { watts(abs($0)) }

        switch battery.state {
        case .charging:
            parts.append(flow.map { "charging at \($0)" } ?? "charging")
            if let full = battery.timeToFull { parts.append("full in \(duration(full))") }
        case .discharging:
            parts.append(flow.map { "on battery, drawing \($0)" } ?? "on battery")
            if let empty = battery.timeToEmpty { parts.append("\(duration(empty)) left") }
        case .charged:
            parts.append("charged, running on the adapter")
        case .held:
            parts.append("plugged in, not charging")
        }

        if let adapter = adapter(battery) { parts.append(adapter) }
        return parts.joined(separator: ", ") + "."
    }

    /// The adapter clause, and nil on battery power, where there is no adapter
    /// to describe.
    private static func adapter(_ battery: BatteryActivity) -> String? {
        guard battery.isPluggedIn else { return nil }
        switch (battery.inputWatts, battery.adapterWatts) {
        case let (input?, rating?): return "adapter delivering \(watts(input)) of \(rated(rating))"
        case let (input?, nil):     return "adapter delivering \(watts(input))"
        case let (nil, rating?):    return "\(rated(rating)) adapter"
        case (nil, nil):            return nil
        }
    }

    static func memory(_ memory: MemoryActivity) -> String {
        var line = "\(bytes(memory.used)) of \(bytes(memory.total)) in use, "
            + "\(percent(memory.usedFraction)). "
            + "Apps \(bytes(memory.app)), wired \(bytes(memory.wired)), "
            + "compressed \(bytes(memory.compressed))."
        if memory.swapUsed > 0 {
            line += " Swap \(bytes(memory.swapUsed)) of \(bytes(memory.swapTotal))."
        }
        return line
    }

    static func traffic(_ traffic: TrafficRate, inbound: String, outbound: String) -> String {
        "\(inbound) \(bytesPerSecond(traffic.inboundBytesPerSecond)), "
        + "\(outbound) \(bytesPerSecond(traffic.outboundBytesPerSecond))."
    }

    /// Nil when the machine is nominal, which is the state worth saying nothing
    /// about.
    static func thermal(_ state: ProcessInfo.ThermalState) -> String? {
        switch state {
        case .nominal:  return nil
        case .fair:     return "thermal state fair"
        case .serious:  return "thermal state serious, the Mac is throttling"
        case .critical: return "thermal state critical, the Mac is throttling hard"
        @unknown default: return nil
        }
    }

    /// The footer sentence for probes that declined to open.
    static func unavailable(_ probes: [String]) -> String? {
        guard !probes.isEmpty else { return nil }
        let list = probes.joined(separator: ", ")
        return probes.count == 1
            ? "One reading is unavailable on this Mac: \(list)."
            : "\(probes.count) readings are unavailable on this Mac: \(list)."
    }
}

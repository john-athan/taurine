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

    static func megahertz(_ value: Double) -> String {
        ActivityFormat.megahertz(value, units: ("megahertz", "gigahertz"))
    }

    static func percent(_ fraction: Double) -> String {
        ActivityFormat.percent(fraction, unit: "percent")
    }

    static func bytes(_ value: UInt64) -> String {
        ActivityFormat.bytes(value, units: ActivityFormat.spokenByteUnits)
    }

    static func bytesPerSecond(_ value: Double) -> String {
        ActivityFormat.bytesPerSecond(value, units: ActivityFormat.spokenRateUnits)
    }

    // MARK: - the tiles

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

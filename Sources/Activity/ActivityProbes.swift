import Foundation

/// The roll call. 📋
///
/// The one place that knows which probes exist and, more importantly, in which
/// order they run. Two of them enrich what an earlier one produced, so the
/// order is part of the behaviour rather than a matter of taste:
///
///   1. `ProcessorProbe` builds the cluster rows.
///   2. `GraphicsProbe` establishes that there is a GPU to talk about.
///   3. `EnergyProbe` writes frequencies onto both of those and adds the watts.
///      It cannot come first, and it does not have to be trusted not to: it
///      declares itself an enricher and the monitor runs it after every
///      measurer whatever this list says. The order here is for readers.
///
/// The rest measure things nobody else touches. Thermal state is read last and
/// drawn first, in the nameplate, because it is a property of the machine
/// rather than a tile of its own.
///
/// This list is deliberately not inside `ActivityMonitor`. The monitor knows
/// how to run probes and nothing about which ones exist, which is what lets a
/// test hand it two fakes and get a full session out of it.
enum ActivityProbes {

    /// Every probe Taurine ships, ready to hand to an `ActivityMonitor`.
    static func standard() -> [ActivityProbe] {
        [
            ProcessorProbe(),
            GraphicsProbe(),
            EnergyProbe(),
            MemoryProbe(),
            StorageProbe(),
            NetworkProbe(),
            ThermalProbe(),
        ]
    }
}

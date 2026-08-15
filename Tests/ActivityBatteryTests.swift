import Foundation

/// The battery probe, against readings captured from a real gauge.
///
/// Everything below `BatteryProbe`'s registry calls is a function of a
/// dictionary, which is what makes this file possible: the machine running the
/// tests is charging or it is not, and a suite that asserted against whatever
/// it happened to be doing would pass for the wrong reason half the time. The
/// dictionaries here are the properties `ioreg -c AppleSmartBattery` printed on
/// a MacBook charging at 20 W from a 30 W adapter, and the same shape edited to
/// describe the states that machine was not in.
///
/// The one check that does run against this Mac is the probe's lifecycle, and
/// it is written to be true on a Mac mini as well: no battery is a state the
/// probe has to open cleanly in, not a failure.
func runActivityBatteryTests() {

    // MARK: - captured readings

    /// Plugged into a 30 W adapter, 47% charged, taking 1731 mA at 11707 mV.
    func charging() -> [String: Any] {
        [
            "CurrentCapacity": 47,
            "MaxCapacity": 100,
            "ExternalConnected": true,
            "IsCharging": true,
            "FullyCharged": false,
            "Amperage": 1731,
            "Voltage": 11707,
            "AvgTimeToFull": 167,
            "AvgTimeToEmpty": 65535,
            "AdapterDetails": ["Watts": 30, "AdapterVoltage": 20000, "Current": 1500],
            "PowerTelemetryData": ["SystemPowerIn": 27898, "SystemLoad": 7634,
                                   "BatteryPower": 20264],
        ]
    }

    /// The same Mac with the cable out, drawing 1500 mA at 11400 mV. The
    /// amperage is written as the unsigned pattern of a negative, which is how
    /// some of these fields come back through Core Foundation.
    func discharging() -> [String: Any] {
        [
            "CurrentCapacity": 62,
            "MaxCapacity": 100,
            "ExternalConnected": false,
            "IsCharging": false,
            "FullyCharged": false,
            "Amperage": NSNumber(value: UInt64(bitPattern: Int64(-1500))),
            "Voltage": 11400,
            "AvgTimeToFull": 65535,
            "AvgTimeToEmpty": 210,
            "PowerTelemetryData": ["SystemPowerIn": 0, "SystemLoad": 17100,
                                   "BatteryPower": NSNumber(value: UInt64(bitPattern: Int64(-17100)))],
        ]
    }

    // MARK: - the flow

    Check.suite("battery, charging") {
        guard let reading = Check.unwrap(BatteryProbe.activity(from: charging()),
                                         "a full reading is understood") else { return }
        Check.close(reading.charge, 0.47, tolerance: 0.001, "state of charge")
        Check.that(reading.isCharging, "the gauge says charging")
        Check.that(reading.isPluggedIn, "the adapter is attached")
        Check.that(reading.state == .charging, "the state is charging")
        Check.close(reading.batteryWatts ?? 0, 20.26, tolerance: 0.01, "watts into the cell")
        Check.close(reading.adapterWatts ?? 0, 30, tolerance: 0.001, "the adapter's rating")
        Check.close(reading.inputWatts ?? 0, 27.898, tolerance: 0.001, "watts in from the wall")
        Check.close(reading.timeToFull ?? 0, 167 * 60, tolerance: 0.5, "time to full")
        Check.isNil(reading.timeToEmpty, "a charging Mac is not emptying")
    }

    Check.suite("battery, discharging") {
        guard let reading = Check.unwrap(BatteryProbe.activity(from: discharging()),
                                         "a reading with no adapter is understood") else { return }
        Check.that(reading.state == .discharging, "the state is discharging")
        // The sign is the direction, and it survives the unsigned spelling.
        Check.close(reading.batteryWatts ?? 0, -17.1, tolerance: 0.01, "watts out of the cell")
        Check.isNil(reading.adapterWatts, "no adapter, no rating")
        Check.isNil(reading.inputWatts, "nothing is coming in")
        Check.close(reading.timeToEmpty ?? 0, 210 * 60, tolerance: 0.5, "time to empty")
        Check.isNil(reading.timeToFull, "a discharging Mac is not filling")
    }

    Check.suite("battery, the states that are not a flow") {
        var full = charging()
        full["IsCharging"] = false
        full["FullyCharged"] = true
        full["CurrentCapacity"] = 100
        Check.that(BatteryProbe.activity(from: full)?.state == .charged,
                   "plugged in and full is charged")

        var limited = charging()
        limited["IsCharging"] = false
        limited["CurrentCapacity"] = 80
        Check.that(BatteryProbe.activity(from: limited)?.state == .held,
                   "plugged in, not full and not charging is held")

        // A laptop at 100% with the cable out is discharging, however full it
        // says it is. Fullness is asked after the plug for exactly this case.
        var unplugged = discharging()
        unplugged["FullyCharged"] = true
        unplugged["CurrentCapacity"] = 100
        Check.that(BatteryProbe.activity(from: unplugged)?.state == .discharging,
                   "full and unplugged is still discharging")
    }

    // MARK: - the arithmetic underneath

    Check.suite("battery, state of charge") {
        // An Intel Mac counts milliamp hours rather than percent, and the
        // ratio has to be the answer in both spellings.
        Check.close(BatteryProbe.charge(from: ["CurrentCapacity": 3351,
                                               "MaxCapacity": 7272]) ?? 0,
                    0.4608, tolerance: 0.001, "milliamp hours divide the same way")
        Check.isNil(BatteryProbe.charge(from: ["CurrentCapacity": 47, "MaxCapacity": 0]),
                    "a maximum of zero is not a battery")
        Check.isNil(BatteryProbe.activity(from: ["IsCharging": true]),
                    "a reading with no charge in it is no reading")
        Check.close(BatteryProbe.charge(from: ["CurrentCapacity": 102,
                                               "MaxCapacity": 100]) ?? 0,
                    1, tolerance: 0.0001, "a gauge over 100% is clamped")
    }

    Check.suite("battery, signed fields") {
        Check.equal(BatteryProbe.signed(1731), 1731, "a plain positive")
        Check.equal(BatteryProbe.signed(NSNumber(value: UInt64(bitPattern: Int64(-1731)))),
                    -1731, "an unsigned pattern is read back as the negative it was")
        Check.equal(BatteryProbe.signed(Int64(-1731)), -1731, "a signed negative")
        Check.isNil(BatteryProbe.signed("1731"), "a string is not a number here")
        Check.isNil(BatteryProbe.signed(nil), "an absent key")

        Check.isNil(BatteryProbe.watts(milliamps: 1731, millivolts: 0),
                    "zero volts is a gauge that has not answered")
        Check.isNil(BatteryProbe.watts(milliamps: 9_000_000, millivolts: 11_707),
                    "a hundred kilowatts is a misread field, not a battery")
    }

    Check.suite("battery, gauge estimates") {
        Check.isNil(BatteryProbe.minutes(BatteryProbe.unknownMinutes),
                    "the sentinel is not an estimate")
        Check.isNil(BatteryProbe.minutes(0), "zero minutes is not an estimate")
        Check.isNil(BatteryProbe.minutes(60 * 48), "two days is not an estimate")
        Check.close(BatteryProbe.minutes(90) ?? 0, 5400, tolerance: 0.5, "minutes become seconds")
    }

    Check.suite("battery, the wall figure is corroborated") {
        let believable = BatteryProbe.inputWatts(from: charging(), batteryWatts: 20.26)
        Check.close(believable ?? 0, 27.898, tolerance: 0.001, "figures that add up are kept")

        // 27.898 W in cannot be 7.634 W of load plus 2 W into the cell.
        var mismatched = charging()
        mismatched["PowerTelemetryData"] = ["SystemPowerIn": 27898, "SystemLoad": 7634,
                                            "BatteryPower": 2000]
        Check.isNil(BatteryProbe.inputWatts(from: mismatched, batteryWatts: 20.26),
                    "telemetry that does not add up is dropped")

        // It adds up with itself but disagrees with current times voltage,
        // which is the independent measurement of the same quantity.
        var disagreeing = charging()
        disagreeing["PowerTelemetryData"] = ["SystemPowerIn": 15634, "SystemLoad": 7634,
                                             "BatteryPower": 8000]
        Check.isNil(BatteryProbe.inputWatts(from: disagreeing, batteryWatts: 20.26),
                    "telemetry that disagrees with the gauge is dropped")

        var absent = charging()
        absent["PowerTelemetryData"] = nil
        Check.isNil(BatteryProbe.inputWatts(from: absent, batteryWatts: 20.26),
                    "a Mac that publishes no telemetry says nothing about the wall")
        Check.close(BatteryProbe.activity(from: absent)?.adapterWatts ?? 0, 30,
                    tolerance: 0.001, "and the adapter's rating is still there to show")
    }

    // MARK: - what the panel says out loud

    Check.suite("battery, spoken") {
        guard let reading = BatteryProbe.activity(from: charging()) else { return }
        let sentence = ActivitySpeech.battery(reading)
        Check.that(sentence.contains("47 percent charged"), "the percentage is spelled out")
        Check.that(sentence.contains("charging at 20.3 watts"), "the flow is spelled out")
        Check.that(sentence.contains("full in 2 hours 47 minutes"), "so is the estimate")
        Check.that(sentence.contains("27.9 watts of 30 watts"), "and the adapter")

        guard let flat = BatteryProbe.activity(from: discharging()) else { return }
        let onBattery = ActivitySpeech.battery(flat)
        Check.that(onBattery.contains("on battery, drawing 17.1 watts"),
                   "discharging is named as such")
        Check.that(onBattery.contains("3 hours 30 minutes left"), "with what it leaves")
        Check.that(!onBattery.contains("adapter"), "and no adapter is invented")
    }

    Check.suite("battery, durations") {
        Check.equal(ActivityFormat.duration(167 * 60), "2 h 47 m", "hours and minutes")
        Check.equal(ActivityFormat.duration(45 * 60), "45 m", "under an hour drops the hours")
        Check.equal(ActivityFormat.duration(0), ActivityFormat.unknown, "nothing is not a span")
        Check.equal(ActivitySpeech.duration(61 * 60), "1 hour 1 minute", "the singular is spoken")
        Check.equal(ActivitySpeech.duration(120 * 60), "2 hours", "a whole number of hours")
    }

    Check.suite("battery, ratings are not measurements") {
        Check.equal(ActivityFormat.wattsRating(30), "30 W", "an adapter's rating is whole watts")
        Check.equal(ActivityFormat.wattsRating(96), "96 W", "and so is a bigger one")
        Check.equal(ActivityFormat.watts(30), "30.0 W",
                    "while a measured 30 W keeps the decimal that can move")
        Check.equal(ActivitySpeech.rated(1), "1 watt", "the singular is spoken")
    }

    // MARK: - against this Mac

    Check.suite("battery, on this machine") {
        let probe = BatteryProbe()
        do {
            try probe.open()
        } catch {
            Check.that(false, "the probe opened (\(error))")
            return
        }
        defer { probe.close() }

        var sample = ActivitySample(uptime: ProcessInfo.processInfo.systemUptime, interval: 1)
        probe.read(into: &sample)

        guard BatteryProbe.machineHasBattery() else {
            Check.isNil(sample.battery, "a Mac with no battery reports none, and does not fail")
            return
        }
        guard let reading = Check.unwrap(sample.battery, "this Mac's battery answered") else { return }
        Check.that(reading.charge >= 0 && reading.charge <= 1, "the charge is a fraction")
        if let watts = reading.batteryWatts {
            Check.that(abs(watts) <= BatteryProbe.plausibleWatts, "the flow is plausible")
            // The sign is the claim worth checking against the gauge's own
            // flags: a charging Mac that reports energy leaving the cell means
            // the sign convention has moved.
            if reading.isCharging { Check.that(watts >= 0, "charging means energy going in") }
            if !reading.isPluggedIn { Check.that(watts <= 0, "unplugged means energy coming out") }
        }
        if let input = reading.inputWatts {
            Check.that(input > 0 && input <= BatteryProbe.plausibleWatts,
                       "the wall figure is plausible")
        }

        // Read after close is inert, like every other probe.
        probe.close()
        var afterwards = ActivitySample(uptime: 1, interval: 1)
        probe.read(into: &afterwards)
        Check.isNil(afterwards.battery, "a closed probe answers nothing")
    }
}

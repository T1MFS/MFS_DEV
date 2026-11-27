import Foundation
import LoopKit

/// Conversions between MFS types and LoopKit types, kept in one place.
/// MFS stores plain numbers in fixed units (glucose mg/dl, sensitivity mg/dl per u, carb ratio c per u, insulin u);
/// LoopKit carries units on its quantities and schedules, so every crossing converts explicitly.

// MARK: Glucose

extension GlucoseReading {
    init(sample: NewGlucoseSample) {
        self.init(date: sample.date, milligramsPerDeciliter: sample.quantity.doubleValue(for: .milligramsPerDeciliter))
    }

    /// Stable per timestamp, so a re-sent reading is recognised.
    var syncIdentifier: String { "mfs-glucose-\(Int(date.timeIntervalSince1970))" }

    var loopSample: NewGlucoseSample {
        NewGlucoseSample(date: date,
                         quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: milligramsPerDeciliter),
                         condition: nil, trend: nil, trendRate: nil,
                         isDisplayOnly: false, wasUserEntered: false,
                         syncIdentifier: syncIdentifier)
    }
}

// MARK: Insulin profile schedules

extension InsulinProfile {
    private func loopItems(_ items: [ScheduleItem]) -> [RepeatingScheduleValue<Double>] {
        items.map { RepeatingScheduleValue(startTime: $0.startTime, value: $0.value) }
    }

    var basalRateSchedule: BasalRateSchedule? {
        scheduleItems { $0.basalUnitsPerHour }.flatMap { BasalRateSchedule(dailyItems: loopItems($0)) }
    }

    var insulinSensitivitySchedule: InsulinSensitivitySchedule? {
        scheduleItems { $0.sensitivityMgdlPerUnit }
            .flatMap { InsulinSensitivitySchedule(unit: .milligramsPerDeciliter, dailyItems: loopItems($0)) }
    }

    /// nil unless every time frame has a carb ratio.
    var carbRatioSchedule: CarbRatioSchedule? {
        scheduleItems { $0.carbRatioGramsPerUnit }
            .flatMap { CarbRatioSchedule(unit: .gramsPerUnit, dailyItems: loopItems($0)) }
    }

    /// A single target per time frame, as a range with equal ends. nil unless every time frame has a target.
    var glucoseTargetSchedule: GlucoseRangeSchedule? {
        scheduleItems { $0.targetMgdl }.flatMap { items in
            GlucoseRangeSchedule(unit: .milligramsPerDeciliter, dailyItems: items.map {
                RepeatingScheduleValue(startTime: $0.startTime, value: DoubleRange(minValue: $0.value, maxValue: $0.value))
            })
        }
    }

    /// Builds a profile from Loop settings. Sensitivity is converted to mg/dl; a target range becomes its midpoint.
    static func fromLoop(name: String, basal: BasalRateSchedule, sensitivity: InsulinSensitivitySchedule,
                         carbRatio: CarbRatioSchedule? = nil, targets: GlucoseRangeSchedule? = nil) -> InsulinProfile? {
        guard let sensitivityMgdl = sensitivity.schedule(for: .milligramsPerDeciliter) else { return nil }
        func items(_ values: [RepeatingScheduleValue<Double>]) -> [ScheduleItem] {
            values.map { ScheduleItem(startTime: $0.startTime, value: $0.value) }
        }
        let targetItems = targets.map { schedule in
            schedule.items.map { item -> ScheduleItem in
                let mid = (item.value.minValue + item.value.maxValue) / 2
                return ScheduleItem(startTime: item.startTime,
                                    value: LoopQuantity(unit: schedule.unit, doubleValue: mid).doubleValue(for: .milligramsPerDeciliter))
            }
        }
        return make(name: name, basal: items(basal.items), sensitivity: items(sensitivityMgdl.items),
                    carbRatio: carbRatio.map { items($0.items) }, target: targetItems)
    }
}

// MARK: Pump history

extension OmnipodHistoryReader.HistoryEvent {
    /// Keeps the dose amounts that the pump kit reports with each event.
    init(_ event: NewPumpEvent) {
        var kind: String?
        var units: Double?
        var perHour: Double?
        var end: Date?
        if let dose = event.dose {
            kind = dose.type.rawValue
            switch dose.type {
            case .bolus:
                units = dose.deliveredUnits ?? dose.programmedUnits
            case .tempBasal, .basal:
                perHour = dose.unitsPerHour
                end = dose.endDate
            case .suspend, .resume:
                break
            }
        }
        self.init(date: event.date, title: event.title, doseKind: kind, units: units, unitsPerHour: perHour, endDate: end)
    }

    var insulinDose: InsulinDose? {
        switch doseKind {
        case "bolus":
            return units.map { InsulinDose(kind: .bolus, start: date, end: date, amount: $0) }
        case "tempBasal", "basal":
            guard let unitsPerHour, let endDate, endDate > date else { return nil }
            return InsulinDose(kind: .basal, start: date, end: endDate, amount: unitsPerHour)
        default:
            return nil
        }
    }
}

extension DeviceActions {
    /// Doses recorded from the pump so far.
    var insulinDoses: [InsulinDose] { omnipod?.history.compactMap(\.insulinDose) ?? [] }
}

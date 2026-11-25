import Foundation
import HealthKit

/// Reads the Apple Health types the user enabled (see `HealthDataKind`) and turns them into biometric samples.
/// Read-only. Uses anchored queries so only new samples are returned; the returned state must be saved
/// only after the upload succeeds, otherwise the readings would be lost.
struct HealthBiometricReader {
    var store = HKHealthStore()
    var calendar = Calendar.current
    /// How far back to look the first time, and for sleep.
    var lookbackDays = 7

    func read(kinds: Set<HealthDataKind>, state: BiometricSyncState, now: Date = Date()) async throws -> BiometricBatch {
        var pending = state
        var samples: [BiometricSample] = []
        let since = calendar.date(byAdding: .day, value: -lookbackDays, to: now) ?? now

        if kinds.contains(.heartRate) {
            let result = try await quantity(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), metric: .heartRate, state: state, since: since)
            samples += result.samples
            pending.set(anchor: result.anchor, for: .heartRate)
        }
        if kinds.contains(.heartRateVariability) {
            let result = try await quantity(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), metric: .heartRateVariability, state: state, since: since)
            samples += result.samples
            pending.set(anchor: result.anchor, for: .heartRateVariability)
        }
        if kinds.contains(.sleep) {
            let nights = try await sleep(after: state.lastSleepSent ?? since, now: now)
            samples += nights
            if let latest = nights.map(\.time).max() { pending.lastSleepSent = latest }
        }
        return BiometricBatch(samples: samples, pendingState: pending)
    }

    private func quantity(
        _ identifier: HKQuantityTypeIdentifier, unit: HKUnit, metric: BiometricMetric, state: BiometricSyncState, since: Date
    ) async throws -> (samples: [BiometricSample], anchor: Data?) {
        let type = HKQuantityType(identifier)
        let anchor = state.anchor(for: metric).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        // The date predicate only bounds the first sync; afterwards the anchor decides what is new.
        let predicate = anchor == nil ? HKQuery.predicateForSamples(withStart: since, end: nil) : nil

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: HKObjectQueryNoLimit) { _, added, _, newAnchor, error in
                if let error { continuation.resume(throwing: error); return }
                let samples = (added ?? []).compactMap { $0 as? HKQuantitySample }.map {
                    BiometricSample(metric: metric, value: $0.quantity.doubleValue(for: unit), time: $0.endDate, id: $0.uuid.uuidString)
                }
                let archived = newAnchor.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
                continuation.resume(returning: (samples, archived))
            }
            store.execute(query)
        }
    }

    private func sleep(after start: Date, now: Date) async throws -> [BiometricSample] {
        let type = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let intervals: [SleepInterval] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                let found = (results ?? []).compactMap { $0 as? HKCategorySample }
                    .filter { asleep.contains($0.value) }
                    .map { SleepInterval(start: $0.startDate, end: $0.endDate) }
                continuation.resume(returning: found)
            }
            store.execute(query)
        }
        // Midnight today: nights that ended earlier are complete.
        return BiometricMapper.sleepNights(from: intervals, before: calendar.startOfDay(for: now), calendar: calendar)
            .filter { $0.time > start }
    }
}

import Foundation

/// A biometric is a measurement of the body's state at a point in time.
/// Glucose is biometric data too, but it keeps its Tidepool types (`cbg`, `smbg`) and is never sent as a `biometric`.
/// Metric names and units mirror the `biometric` type in fx2-t1d/TidepoolApi_extended
/// (reference/data/models/biometric) and DigitalMe's `POST /biometrics/upload`. Keep the three in sync.
enum BiometricMetric: String, CaseIterable {
    case heartRate
    case heartRateVariability
    case sleepDuration

    var units: String {
        switch self {
        case .heartRate: return "bpm"
        case .heartRateVariability: return "ms"
        case .sleepDuration: return "minutes"
        }
    }
}

struct BiometricSample: Equatable {
    var metric: BiometricMetric
    var value: Double
    var time: Date
    /// Stable id of the source sample, so a re-sent reading is recognisable.
    var id: String
}

/// A span of time the person was asleep, from Apple Health sleep analysis.
struct SleepInterval: Equatable {
    var start: Date
    var end: Date
}

enum BiometricMapper {
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// The Tidepool-format `biometric` datum for one sample.
    static func datum(_ sample: BiometricSample) -> [String: Any] {
        [
            "type": "biometric",
            "metric": sample.metric.rawValue,
            "id": sample.id,
            "time": timestamp(sample.time),
            "amount": ["value": sample.value, "units": sample.metric.units],
        ]
    }

    static func records(_ samples: [BiometricSample]) -> [[String: Any]] {
        samples.map(datum)
    }

    /// Sleep arrives as many overlapping segments (stages, several sources). Merge overlaps so time is not double counted,
    /// then total each night, where a night is the calendar day it ended on. Only nights that ended before `before`
    /// are returned, so a night still in progress is not sent half-finished.
    static func sleepNights(from intervals: [SleepInterval], before: Date, calendar: Calendar = .current) -> [BiometricSample] {
        let valid = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [SleepInterval] = []
        for interval in valid {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }

        var nights: [Date: (minutes: Double, end: Date)] = [:]
        for interval in merged where interval.end <= before {
            let day = calendar.startOfDay(for: interval.end)
            let minutes = interval.end.timeIntervalSince(interval.start) / 60
            let existing = nights[day]
            nights[day] = ((existing?.minutes ?? 0) + minutes, max(existing?.end ?? interval.end, interval.end))
        }
        return nights.keys.sorted().compactMap { day in
            guard let night = nights[day] else { return nil }
            return BiometricSample(
                metric: .sleepDuration,
                value: night.minutes.rounded(),
                time: night.end,
                id: "mfs-sleep-\(Int(day.timeIntervalSince1970))")
        }
    }
}

/// What has already been sent, so each reading goes out once. Committed only after DigitalMe accepts an upload.
struct BiometricSyncState: Codable, Equatable {
    /// Archived `HKQueryAnchor` per metric.
    var anchors: [String: Data] = [:]
    /// End of the most recent sleep night already sent.
    var lastSleepSent: Date?

    func anchor(for metric: BiometricMetric) -> Data? { anchors[metric.rawValue] }

    mutating func set(anchor: Data?, for metric: BiometricMetric) { anchors[metric.rawValue] = anchor }

    private static let key = "biometricSyncState"

    static func load(from defaults: UserDefaults = .standard) -> BiometricSyncState {
        guard let data = defaults.data(forKey: key), let state = try? JSONDecoder().decode(BiometricSyncState.self, from: data) else {
            return BiometricSyncState()
        }
        return state
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// Samples read from Apple Health plus the state to commit once they have been uploaded.
struct BiometricBatch {
    var samples: [BiometricSample]
    var pendingState: BiometricSyncState
    var records: [[String: Any]] { BiometricMapper.records(samples) }
}

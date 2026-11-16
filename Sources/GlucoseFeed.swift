import Foundation

/// Glucose readings shown by the UI, fed by whichever CGM host is active.
final class GlucoseFeed: ObservableObject {
    @Published private(set) var readings: [GlucoseReading] = []

    func merge(_ new: [GlucoseReading]) {
        let known = Set(readings.map(\.date))
        readings = (readings + new.filter { !known.contains($0.date) }).sorted { $0.date < $1.date }
    }
}

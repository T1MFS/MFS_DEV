import Foundation

/// Glucose readings shown by the UI, fed by whichever CGM host is active.
/// Every reading is kept on the device across launches and new builds.
final class GlucoseFeed: ObservableObject {
    @Published private(set) var readings: [GlucoseReading]
    private let store: HistoryStore<GlucoseReading>?

    init(store: HistoryStore<GlucoseReading>? = HistoryStore(filename: "glucose-history.json")) {
        self.store = store
        readings = (store?.load() ?? []).sorted { $0.date < $1.date }
    }

    func merge(_ new: [GlucoseReading]) {
        let known = Set(readings.map(\.date))
        let added = new.filter { !known.contains($0.date) }
        guard !added.isEmpty else { return }
        readings = (readings + added).sorted { $0.date < $1.date }
        store?.save(readings)
    }
}

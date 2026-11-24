import Foundation
import HealthKit

/// Read-only FreeStyle Libre 3 integration through the glucose samples written by
/// the official Libre app to HealthKit.
final class Libre3GlucoseHost: NSObject, ObservableObject, DeviceConnection {
    @Published private(set) var isEnabled = false
    @Published private(set) var authorizationDenied = false

    private let healthStore = HKHealthStore()
    private let feed: GlucoseFeed
    private let glucoseType = HKObjectType.quantityType(forIdentifier: .bloodGlucose)!
    private var observerQuery: HKObserverQuery?
    private var latestDate: Date?

    init(feed: GlucoseFeed) {
        self.feed = feed
        super.init()
    }

    var hasConnectedDevice: Bool { isEnabled }

    func disconnect() {
        if let observerQuery {
            healthStore.stop(observerQuery)
        }
        observerQuery = nil
        isEnabled = false
    }

    func beginPairing() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        healthStore.requestAuthorization(toShare: [], read: [glucoseType]) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationDenied = !success || error != nil
                guard success else { return }
                self.isEnabled = true
                self.startObserving()
                self.fetchNewData()
            }
        }
    }

    func fetchNewData() {
        guard isEnabled else { return }
        let start = latestDate ?? Date().addingTimeInterval(-24 * 60 * 60)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let query = HKSampleQuery(
            sampleType: glucoseType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { [weak self] _, samples, _ in
            guard let self else { return }
            let unit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
            let readings = (samples as? [HKQuantitySample] ?? [])
                .filter { self.isLibreSource($0.sourceRevision.source.name) }
                .map {
                    GlucoseReading(
                        date: $0.startDate,
                        milligramsPerDeciliter: $0.quantity.doubleValue(for: unit)
                    )
                }
            guard !readings.isEmpty else { return }
            self.latestDate = readings.map(\.date).max()
            DispatchQueue.main.async { self.feed.merge(readings) }
        }
        healthStore.execute(query)
    }

    private func startObserving() {
        guard observerQuery == nil else { return }
        let query = HKObserverQuery(sampleType: glucoseType, predicate: nil) { [weak self] _, completion, _ in
            self?.fetchNewData()
            completion()
        }
        observerQuery = query
        healthStore.execute(query)
    }

    private func isLibreSource(_ name: String) -> Bool {
        let source = name.localizedLowercase
        return source.contains("libre") || source.contains("freestyle")
    }
}

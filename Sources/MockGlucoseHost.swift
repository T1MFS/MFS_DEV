import Foundation
import HealthKit
import LoopKit
import MockKit

/// Development glucose source backed by LoopKit's `MockCGMManager`.
/// Enabled with the launch argument `-MFSMockCGM YES`.
final class MockGlucoseHost: CGMHostBase {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "MFSMockCGM") }

    private let manager = MockCGMManager()

    init(feed: GlucoseFeed) {
        super.init(feed: feed, queueLabel: "MFS.MockGlucoseHost")
        manager.dataSource = MockCGMDataSource(
            model: .sineCurve(parameters: (
                baseGlucose: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 130),
                amplitude: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 40),
                period: 4 * 3600,
                referenceDate: Date()
            ))
        )
        manager.cgmManagerDelegate = self
        manager.backfillData(datingBack: 3 * 3600)
    }

    func fetchNewData() {
        manager.fetchNewDataIfNeeded { [weak self] result in
            self?.handle(result)
        }
    }

    override var credentialPrefix: String { "MFS.Mock" }
}

import Foundation
import LibreLoop
import LoopKit

/// Hosts LibreLoop's direct BLE FreeStyle Libre 3/3+ CGM manager.
final class Libre3GlucoseHost: CGMHostBase, ObservableObject, DeviceConnection {
    @Published private(set) var isEnabled = false
    @Published private(set) var pairingInProgress = false
    @Published private(set) var pairingError: String?
    private let store: DeviceStateStore
    private(set) var manager: LibreLoopCGMManager

    init(feed: GlucoseFeed, store: DeviceStateStore = DeviceStateStore(key: "MFS.LibreLoop.rawState")) {
        self.store = store
        if let rawState = store.load(), let restored = LibreLoopCGMManager(rawState: rawState) {
            manager = restored
        } else {
            manager = LibreLoopCGMManager()
        }
        super.init(feed: feed, queueLabel: "MFS.Libre3GlucoseHost")
        manager.cgmManagerDelegate = self
        store.save(manager.rawState)
        isEnabled = manager.state.sensorSerial != nil
        DiagnosticsLog.shared.record(diagnosticsName, "Started. Saved sensor: \(isEnabled ? "yes" : "none")")
        // Only resume listening for a sensor that was already paired; never scan unprompted.
        if isEnabled { _ = manager.scanner }
    }

    var hasConnectedDevice: Bool { isEnabled }

    /// Facts about the paired sensor, for the Troubleshooting screen.
    var diagnosticSnapshot: [(String, String)] {
        let state = manager.state
        func time(_ date: Date?) -> String { date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "never" }
        var rows: [(String, String)] = [
            ("Sensor serial", state.sensorSerial ?? "none"),
            ("Paired at", time(state.lastPairedAt)),
            ("Activated at", time(state.activatedAt)),
            ("BLE address", state.bleAddress ?? "none"),
            ("BLE PIN saved", state.blePIN == nil ? "no" : "yes"),
            ("Peripheral saved", state.peripheralID == nil ? "no" : "yes"),
            ("First reading", time(state.firstReadingAt)),
            ("Latest reading", time(state.latestReadingTimestamp)),
            ("Last forwarded", time(state.latestForwardedToLoopAt)),
            ("Recent samples held", String(state.recentSamples.count)),
            ("Firmware", state.firmwareVersion ?? "unknown"),
        ]
        if let paired = state.lastPairedAt, state.firstReadingAt == nil {
            let warmup = state.warmupDurationMinutes ?? 60
            let ends = paired.addingTimeInterval(Double(warmup) * 60)
            rows.append(("Warm-up", ends > Date() ? "until about \(time(ends)) (\(warmup) min)" : "should be over (\(warmup) min)"))
        }
        return rows
    }

    func disconnect() {
        DiagnosticsLog.shared.record(diagnosticsName, "Disconnect requested")
        manager.discardSensor()
        isEnabled = false
    }

    func beginPairing() {
        guard !pairingInProgress else { return }
        pairingInProgress = true
        pairingError = nil
        DiagnosticsLog.shared.record(diagnosticsName, "Pairing started")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let service = LibreLoopPairingService()
                let outcome = try await service.pair(
                    mode: .fresh,
                    scanner: manager.scanner,
                    onNFCResponse: { [manager] response in
                        manager.applyNFCResponse(response)
                    }
                )
                try manager.applyPairingOutcome(outcome)
                store.save(manager.rawState)
                isEnabled = true
                DiagnosticsLog.shared.record(diagnosticsName, "Pairing succeeded")
            } catch {
                pairingError = String(describing: error)
                DiagnosticsLog.shared.record(diagnosticsName, "Pairing failed: \(error)")
            }
            pairingInProgress = false
        }
    }

    func fetchNewData() {
        guard isEnabled else { return }
        DiagnosticsLog.shared.record(diagnosticsName, "Refresh requested")
        _ = manager.scanner
    }

    override func handle(_ result: CGMReadingResult) {
        super.handle(result)
        store.save(manager.rawState)
    }

    override func stateDidChange(_ manager: CGMManager) {
        store.save(manager.rawState)
    }

    override func wantsDeletion(_ manager: CGMManager) {
        store.clear()
    }
}

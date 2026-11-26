import SwiftUI

/// Menu of what may be streamed to DigitalMe. One approval applies until stopped.
struct BiometricStreamView: View {
    @EnvironmentObject private var stream: BiometricStream
    @EnvironmentObject private var serviceStore: ServiceConnectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var chosenID: UUID?

    private var connectionID: UUID? { stream.consent.connectionID ?? chosenID ?? serviceStore.connections.first(where: \.enabled)?.id }

    var body: some View {
        NavigationStack {
            Form {
                Section("Send to") {
                    if serviceStore.connections.filter(\.enabled).isEmpty {
                        Text("Add a DigitalMe address under Service connections first.").foregroundStyle(.secondary)
                    } else {
                        Picker("DigitalMe", selection: Binding(get: { connectionID }, set: { chosenID = $0 })) {
                            ForEach(serviceStore.connections.filter(\.enabled)) { Text($0.name.isEmpty ? $0.baseURL : $0.name).tag(Optional($0.id)) }
                        }
                        .disabled(stream.consent.isActive)
                    }
                }
                Section {
                    ForEach(HealthDataKind.allCases) { kind in
                        Toggle(isOn: Binding(
                            get: { stream.consent.approved.contains(kind) },
                            set: { on in if let id = connectionID { stream.setApproved(kind, on, connectionID: id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.label)
                                Text(kind.streamNote).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(connectionID == nil)
                    }
                } header: {
                    Text("What to send")
                } footer: {
                    Text("Approve once. Each new glucose reading then sends whatever is new for the items you turned on, as long as the app is running and Apple Health access is granted. Turn an item off, or choose Stop, to end it.")
                }
                Section("Status") { status }
            }
            .navigationTitle("Biometric stream")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder private var status: some View {
        let consent = stream.consent
        if !consent.isActive {
            Label("Off", systemImage: "pause.circle").foregroundStyle(.secondary)
        } else if let reason = consent.pausedReason {
            Label("Paused", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(reason).font(.footnote)
            Text("Review the connection under Service connections, then resume.").font(.footnote).foregroundStyle(.secondary)
            Button("Resume streaming") { stream.resume() }
        } else {
            Label("Streaming", systemImage: "dot.radiowaves.up.forward").foregroundStyle(.green)
        }
        if let sent = stream.lastSent {
            LabeledContent("Last sent", value: "\(stream.lastSentCount) at \(sent.formatted(date: .omitted, time: .shortened))")
        }
        if let error = stream.lastError, consent.pausedReason == nil {
            Text("Will retry with the next reading: \(error)").font(.footnote).foregroundStyle(.secondary)
        }
        if consent.isActive {
            Button("Stop streaming", role: .destructive) { stream.stop() }
        }
    }
}

extension HealthDataKind {
    /// When this kind goes out, relative to glucose readings.
    var streamNote: String {
        switch self {
        case .heartRate: return "New samples with each glucose reading; none, one or several."
        case .heartRateVariability: return "New samples with a reading when Apple Health has recorded any."
        case .sleep: return "One total per night, sent after the night has ended."
        }
    }
}

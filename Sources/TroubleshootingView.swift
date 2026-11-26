import LibreLoop
import SwiftUI

/// Where data stops: sensor state, what reached the app, and the recent logs, with a way to share them.
struct TroubleshootingView: View {
    @ObservedObject var host: Libre3GlucoseHost
    @EnvironmentObject private var feed: GlucoseFeed
    @ObservedObject private var log = DiagnosticsLog.shared
    @ObservedObject private var libreLog = LibreLoopFileLogger.shared

    private var stats: PipelineStats { log.stats[host.diagnosticsName] ?? PipelineStats() }

    private func time(_ date: Date?) -> String {
        date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "never"
    }

    private var report: String {
        var text = "MFS FreeStyle Libre 3 troubleshooting report \(Date().formatted())\n\n"
        text += "Sensor\n" + host.diagnosticSnapshot.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        text += "\n\nReached MFS\nCallbacks: \(stats.callbacks)\nSamples received: \(stats.samplesReceived)\nSamples added to chart: \(stats.samplesMerged)\nLast result: \(stats.lastResult) at \(time(stats.lastResultAt))\nChart readings: \(feed.readings.count)"
        text += "\n\nMFS log\n" + log.lines.suffix(200).joined(separator: "\n")
        text += "\n\nLibreLoop log\n" + libreLog.recentLines.suffix(200).joined(separator: "\n")
        return text
    }

    var body: some View {
        List {
            Section("Sensor") {
                ForEach(host.diagnosticSnapshot, id: \.0) { LabeledContent($0.0, value: $0.1) }
                LabeledContent("Paired in app", value: host.isEnabled ? "yes" : "no")
            }
            Section {
                LabeledContent("Callbacks from sensor", value: "\(stats.callbacks)")
                LabeledContent("Samples received", value: "\(stats.samplesReceived)")
                LabeledContent("Added to chart", value: "\(stats.samplesMerged)")
                LabeledContent("Readings in chart", value: "\(feed.readings.count)")
                LabeledContent("Newest sample", value: time(stats.newestSampleDate))
                LabeledContent("Last result", value: stats.lastResult)
                LabeledContent("At", value: time(stats.lastResultAt))
            } header: {
                Text("Reached MFS")
            } footer: {
                Text("Latest reading set but samples received 0: the sensor produced data that never reached the app. Samples received above 0 but none added: they were duplicates. A new sensor can take about an hour to warm up before any reading.")
            }
            Section {
                ShareLink("Share report", item: report)
                Button("Check for new readings") { host.fetchNewData() }
                Button("Clear MFS log", role: .destructive) { log.clear() }
            }
            logSection("MFS log", lines: log.lines)
            logSection("LibreLoop log", lines: libreLog.recentLines)
        }
        .navigationTitle("Troubleshooting")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func logSection(_ title: String, lines: [String]) -> some View {
        Section(title) {
            if lines.isEmpty {
                Text("Nothing logged yet.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(lines.suffix(100).reversed().enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
}

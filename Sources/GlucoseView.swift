import SwiftUI
import Charts

/// Glucose trend with a movable meal marker, shown as sections inside the Manage list.
/// The chart scrolls sideways through history; the range under it sets how many hours are visible.
/// Food and dose do not influence the forecast yet.
struct GlucoseView: View {
    @EnvironmentObject private var feed: GlucoseFeed
    @EnvironmentObject private var store: AcceptedFoodStore

    private let forecaster = GlucoseForecaster()
    private let window: TimeInterval = 2 * 60 * 60
    private static let rangeHours = [1, 3, 6, 12, 24]

    @State private var rangeHours = 3
    @State private var scrollPosition = Date()

    private var readings: [GlucoseReading] { feed.readings }
    private var anchor: Date { readings.last?.date ?? Date() }
    private var mealTime: Date { store.mealTime ?? anchor }
    private var visibleLength: TimeInterval { TimeInterval(rangeHours) * 3600 }
    /// Forecast shown past the latest reading; a short range shows a shorter stretch of it.
    private var lookahead: TimeInterval { min(window, visibleLength / 3) }
    private var domain: ClosedRange<Date> {
        let end = anchor.addingTimeInterval(window)
        let start = min(readings.first?.date ?? anchor, end.addingTimeInterval(-visibleLength))
        return start...end
    }
    private var latestPosition: Date { anchor.addingTimeInterval(lookahead - visibleLength) }

    private var context: ForecastContext {
        let foods = store.food.map {
            [FoodEvent(time: mealTime, carbohydrates: $0.totalCarbohydrates, protein: $0.totalProtein, fat: $0.totalFat)]
        } ?? []
        return ForecastContext(readings: readings, foods: foods, doses: [])
    }

    private var forecast: [ForecastPoint] { forecaster.points(context: context, horizon: window) }

    var body: some View {
        Group {
            Section("Glucose") {
                if let latest = readings.last {
                    header(latest)
                    chart
                    rangePicker
                    Text("Forecast is the latest reading held flat. Food and dose do not influence it yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No glucose readings yet.")
                        .foregroundStyle(.secondary)
                }
            }
            if store.food != nil, !readings.isEmpty {
                Section("Meal time") {
                    Text(mealTimeDescription)
                    Text("Drag the dot on the chart in 5-minute steps.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if store.mealTime != nil {
                        Button("Reset to now") { store.mealTime = nil }
                    }
                }
            }
        }
    }

    private func header(_ latest: GlucoseReading) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(latest.milligramsPerDeciliter.formatted(.number.precision(.fractionLength(0))))
                .font(.largeTitle.bold())
            Text("mg/dL").foregroundStyle(.secondary)
            if let trend = GlucoseTrendCalculator.trend(of: readings) {
                Image(systemName: trend.symbolName).font(.title2)
            }
            Spacer()
            Text(latest.date, style: .time).foregroundStyle(.secondary)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 6) {
            Spacer()
            ForEach(Self.rangeHours, id: \.self) { hours in
                Button {
                    rangeHours = hours
                    scrollPosition = latestPosition
                } label: {
                    Text("\(hours)")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 26, minHeight: 22)
                        .background(rangeHours == hours ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(rangeHours == hours ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Text("h").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chart range in hours")
    }

    private var chart: some View {
        Chart {
            ForEach(readings) { reading in
                LineMark(x: .value("Time", reading.date),
                         y: .value("mg/dL", reading.milligramsPerDeciliter),
                         series: .value("Series", "Glucose"))
                    .foregroundStyle(.blue)
            }
            ForEach(forecast) { point in
                LineMark(x: .value("Time", point.date),
                         y: .value("mg/dL", point.milligramsPerDeciliter),
                         series: .value("Series", "Forecast"))
                    .foregroundStyle(.gray)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: yDomain)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleLength)
        .chartScrollPosition(x: $scrollPosition)
        .chartOverlay { proxy in mealMarker(proxy) }
        .frame(height: 260)
        .onAppear { scrollPosition = latestPosition }
        .onChange(of: readings.last?.date) { old, _ in
            // Follow new readings only while the chart is showing the latest.
            if let old, abs(scrollPosition.timeIntervalSince(old.addingTimeInterval(lookahead - visibleLength))) < 60 {
                scrollPosition = latestPosition
            }
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = readings.map(\.milligramsPerDeciliter)
        let low = min(70, (values.min() ?? 70) - 10)
        let high = max(180, (values.max() ?? 180) + 10)
        return low...high
    }

    /// A translucent black dot at the meal time, so the reading under it stays visible. Drag it to move the meal.
    @ViewBuilder
    private func mealMarker(_ proxy: ChartProxy) -> some View {
        if store.food != nil, let plotFrame = proxy.plotFrame {
            GeometryReader { geometry in
                let frame = geometry[plotFrame]
                if let x = proxy.position(forX: mealTime), let y = proxy.position(forY: glucose(at: mealTime)),
                   x >= 0, x <= frame.width {
                    Circle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: 14, height: 14)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                        .position(x: frame.origin.x + x, y: frame.origin.y + y)
                        .gesture(
                            DragGesture(coordinateSpace: .named("glucoseOverlay"))
                                .onChanged { drag in
                                    guard let date: Date = proxy.value(atX: drag.location.x - frame.origin.x) else { return }
                                    let clamped = min(max(date, domain.lowerBound), domain.upperBound)
                                    store.mealTime = clamped.snapped(toFiveMinutesFrom: anchor)
                                }
                        )
                }
            }
            .coordinateSpace(name: "glucoseOverlay")
        }
    }

    /// Glucose or forecast value nearest to the given time.
    private func glucose(at date: Date) -> Double {
        let candidates = readings.map { ($0.date, $0.milligramsPerDeciliter) }
            + forecast.map { ($0.date, $0.milligramsPerDeciliter) }
        return candidates.min { abs($0.0.timeIntervalSince(date)) < abs($1.0.timeIntervalSince(date)) }?.1 ?? 0
    }

    private var mealTimeDescription: String {
        let minutes = Int((mealTime.timeIntervalSince(anchor) / 60).rounded())
        switch minutes {
        case 0: return "Now (latest reading)"
        case ..<0: return "Started \(-minutes) min before the latest reading"
        default: return "Starting \(minutes) min after the latest reading"
        }
    }
}

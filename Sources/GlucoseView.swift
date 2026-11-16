import SwiftUI
import Charts

/// Glucose trend with a movable meal marker, shown as sections inside the Manage list.
/// Food and dose do not influence the forecast yet.
struct GlucoseView: View {
    @EnvironmentObject private var feed: GlucoseFeed
    @EnvironmentObject private var store: AcceptedFoodStore

    private let forecaster = GlucoseForecaster()
    private let window: TimeInterval = 2 * 60 * 60

    private var readings: [GlucoseReading] { feed.readings }
    private var anchor: Date { readings.last?.date ?? Date() }
    private var mealTime: Date { store.mealTime ?? anchor }
    private var domain: ClosedRange<Date> { anchor.addingTimeInterval(-window)...anchor.addingTimeInterval(window) }

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
                    Text("Drag the pie chart along the line in 5-minute steps.")
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

    private var chart: some View {
        Chart {
            ForEach(readings.filter { domain.contains($0.date) }) { reading in
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
        .chartOverlay { proxy in mealMarker(proxy) }
        .frame(height: 260)
    }

    private var yDomain: ClosedRange<Double> {
        let values = readings.map(\.milligramsPerDeciliter)
        let low = min(70, (values.min() ?? 70) - 10)
        let high = max(180, (values.max() ?? 180) + 10)
        return low...high
    }

    @ViewBuilder
    private func mealMarker(_ proxy: ChartProxy) -> some View {
        if let food = store.food, let plotFrame = proxy.plotFrame {
            GeometryReader { geometry in
                let origin = geometry[plotFrame].origin
                if let x = proxy.position(forX: mealTime), let y = proxy.position(forY: glucose(at: mealTime)) {
                    MacroPieChart(food: food, height: 56, compact: true)
                        .position(x: origin.x + x, y: origin.y + y)
                        .gesture(
                            DragGesture(coordinateSpace: .named("glucoseOverlay"))
                                .onChanged { drag in
                                    guard let date: Date = proxy.value(atX: drag.location.x - origin.x) else { return }
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

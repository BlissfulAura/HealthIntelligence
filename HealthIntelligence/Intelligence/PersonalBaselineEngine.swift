//
//  PersonalBaselineEngine.swift
//  HealthIntelligence
//
//  Turns a daily time series for one metric into MetricBaseline + MetricState
//  values, using only the individual's own history. Deliberately no fixed
//  universal thresholds anywhere in this file — "meaningfully different"
//  means "different relative to this person's own mean and variability,"
//  measured in that person's own standard deviations.
//
//  Pipeline stage: Health Data -> [this] -> Signal Detection -> ...
//
//  Pure and HealthKit-independent — takes a plain `[Date: Double]` series,
//  so it's directly unit-testable with synthetic data (see
//  PersonalBaselineEngineTests).
//

import Foundation

struct PersonalBaselineEngine {
    /// How many days of history (immediately preceding the recent window)
    /// are used to compute "normal" for this person. Kept separate from the
    /// recent window so the days being evaluated can't contaminate their
    /// own reference point.
    var baselineWindowDays: Int = 45

    /// Z-score magnitude beyond which a day counts as meaningfully
    /// different from personal baseline. Expressed in the individual's own
    /// standard deviations, not a fixed universal unit — someone with more
    /// day-to-day RHR variability needs a bigger absolute swing to trip this
    /// than someone very stable.
    var abnormalityThreshold: Double = 1.5

    /// Minimum fraction of day-over-day deltas that must agree in direction
    /// for a slope to be called a sustained trend rather than noise.
    var trendConsistencyThreshold: Double = 0.65

    init() {}

    /// Builds one MetricState per day in the most recent `recentWindowDays`
    /// that has data, each baselined against the `baselineWindowDays`
    /// immediately before it.
    ///
    /// - Parameter series: daily values keyed by calendar-day start date.
    ///   Days with no entry are simply skipped (no data does not mean
    ///   "abnormal" — it means nothing can be said).
    func metricStates(
        metric: IntelligenceMetric,
        series: [Date: Double],
        referenceDate: Date,
        recentWindowDays: Int = 7,
        calendar: Calendar = .current
    ) -> [MetricState] {
        guard !series.isEmpty else { return [] }

        let startOfReferenceDate = calendar.startOfDay(for: referenceDate)
        var recentDates: [Date] = []
        for offset in stride(from: recentWindowDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfReferenceDate) else { continue }
            recentDates.append(day)
        }

        var states: [MetricState] = []
        var runningAbnormalStreak = 0

        for day in recentDates {
            guard let value = series[day] else {
                runningAbnormalStreak = 0
                continue
            }

            let baselineValues = Self.values(from: series, from: nil, upTo: day, windowDays: baselineWindowDays, calendar: calendar)
            let baseline = Self.computeBaseline(from: baselineValues)
            let deviation = baseline?.zScore(for: value)
            let percentile = baseline != nil ? Self.empiricalPercentile(of: value, in: baselineValues) : nil

            let isAbnormal = deviation.map { abs($0) >= abnormalityThreshold } ?? false
            runningAbnormalStreak = isAbnormal ? runningAbnormalStreak + 1 : 0

            let trend = Self.trend(
                series: series,
                endingAt: day,
                windowDays: recentWindowDays,
                calendar: calendar,
                consistencyThreshold: trendConsistencyThreshold
            )

            states.append(MetricState(
                metric: metric,
                date: day,
                currentValue: value,
                baseline: baseline,
                deviation: deviation,
                percentile: percentile,
                trend: trend,
                daysAbnormal: runningAbnormalStreak
            ))
        }

        return states
    }

    // MARK: - Baseline statistics

    /// `nil` below 3 data points — not enough to say anything about
    /// variance. `MetricBaseline.isReliable` (14 days) is the separate,
    /// stricter gate signal detection actually uses.
    static func computeBaseline(from values: [Double]) -> MetricBaseline? {
        guard values.count >= 3 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return MetricBaseline(mean: mean, standardDeviation: sqrt(variance), sampleCount: values.count)
    }

    static func empiricalPercentile(of value: Double, in values: [Double]) -> Double {
        guard !values.isEmpty else { return 50 }
        let countAtOrBelow = values.filter { $0 <= value }.count
        return Double(countAtOrBelow) / Double(values.count) * 100
    }

    private static func values(from series: [Date: Double], from lowerBound: Date?, upTo day: Date, windowDays: Int, calendar: Calendar) -> [Double] {
        guard let start = calendar.date(byAdding: .day, value: -windowDays, to: day) else { return [] }
        return series.compactMap { key, value in
            (key >= start && key < day) ? value : nil
        }
    }

    // MARK: - Trend

    static func trend(
        series: [Date: Double],
        endingAt day: Date,
        windowDays: Int,
        calendar: Calendar,
        consistencyThreshold: Double
    ) -> TrendResult? {
        var points: [(x: Double, y: Double)] = []
        for offset in stride(from: windowDays - 1, through: 0, by: -1) {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: day), let value = series[d] else { continue }
            points.append((x: Double(windowDays - 1 - offset), y: value))
        }
        // Need enough points for a slope to mean anything.
        guard points.count >= 4 else { return nil }

        let slope = leastSquaresSlope(points)

        var agreeing = 0
        var compared = 0
        for i in 1..<points.count {
            let delta = points[i].y - points[i - 1].y
            if delta == 0 { continue }
            compared += 1
            if (delta > 0) == (slope > 0) { agreeing += 1 }
        }
        let consistency = compared > 0 ? Double(agreeing) / Double(compared) : 0

        let direction: TrendDirection
        if abs(slope) < .ulpOfOne {
            direction = .stable
        } else {
            direction = slope > 0 ? .rising : .falling
        }

        let isSustained = direction != .stable && consistency >= consistencyThreshold

        return TrendResult(direction: direction, slopePerDay: slope, consistency: consistency, isSustained: isSustained)
    }

    private static func leastSquaresSlope(_ points: [(x: Double, y: Double)]) -> Double {
        let n = Double(points.count)
        let sumX = points.reduce(0) { $0 + $1.x }
        let sumY = points.reduce(0) { $0 + $1.y }
        let sumXY = points.reduce(0) { $0 + $1.x * $1.y }
        let sumXX = points.reduce(0) { $0 + $1.x * $1.x }
        let denominator = n * sumXX - sumX * sumX
        guard denominator != 0 else { return 0 }
        return (n * sumXY - sumX * sumY) / denominator
    }
}

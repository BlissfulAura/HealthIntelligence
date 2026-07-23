//
//  PersonalBaselineEngineTests.swift
//  HealthIntelligenceTests
//
//  Coverage for the statistics that everything else in the intelligence
//  pipeline depends on: baseline mean/SD/reliability, empirical percentile,
//  per-day MetricState construction (deviation, daysAbnormal streaks), and
//  trend detection (sustained vs. noisy).
//

import XCTest
@testable import HealthIntelligence

final class PersonalBaselineEngineTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000) // fixed, environment-independent

    private func day(_ offset: Int, from date: Date? = nil) -> Date {
        let base = calendar.startOfDay(for: date ?? referenceDate)
        return calendar.date(byAdding: .day, value: offset, to: base)!
    }

    // MARK: - MetricBaseline

    func test_computeBaseline_requiresAtLeastThreePoints() {
        XCTAssertNil(PersonalBaselineEngine.computeBaseline(from: [1, 2]))
        XCTAssertNotNil(PersonalBaselineEngine.computeBaseline(from: [1, 2, 3]))
    }

    func test_computeBaseline_meanAndStandardDeviation() {
        let baseline = PersonalBaselineEngine.computeBaseline(from: [10, 20, 30])!
        XCTAssertEqual(baseline.mean, 20, accuracy: 0.001)
        XCTAssertEqual(baseline.standardDeviation, 8.1650, accuracy: 0.001)
        XCTAssertEqual(baseline.sampleCount, 3)
    }

    func test_baseline_isReliable_atMinimumSampleCountThreshold() {
        let unreliable = MetricBaseline(mean: 60, standardDeviation: 5, sampleCount: MetricBaseline.minimumReliableSampleCount - 1)
        let reliable = MetricBaseline(mean: 60, standardDeviation: 5, sampleCount: MetricBaseline.minimumReliableSampleCount)
        XCTAssertFalse(unreliable.isReliable)
        XCTAssertTrue(reliable.isReliable)
    }

    func test_zScore_nilWhenNoVariance() {
        let baseline = MetricBaseline(mean: 60, standardDeviation: 0, sampleCount: 20)
        XCTAssertNil(baseline.zScore(for: 65))
    }

    // MARK: - Empirical percentile

    func test_empiricalPercentile_ranksAgainstHistory() {
        let values: [Double] = [1, 2, 3, 4, 5]
        XCTAssertEqual(PersonalBaselineEngine.empiricalPercentile(of: 3, in: values), 60, accuracy: 0.001)
        XCTAssertEqual(PersonalBaselineEngine.empiricalPercentile(of: 5, in: values), 100, accuracy: 0.001)
        XCTAssertEqual(PersonalBaselineEngine.empiricalPercentile(of: 0, in: values), 0, accuracy: 0.001)
    }

    // MARK: - MetricState construction

    func test_metricStates_flagsSpikeAgainstStableBaseline() {
        var series: [Date: Double] = [:]
        for offset in -52...(-8) {
            series[day(offset)] = 60
        }
        // A little real variance so the baseline has a nonzero SD — a
        // perfectly flat history would make zScore() return nil.
        series[day(-10)] = 62
        series[day(-9)] = 58
        for offset in -6...(-1) {
            series[day(offset)] = 60
        }
        series[day(0)] = 90 // today's spike

        let engine = PersonalBaselineEngine()
        let states = engine.metricStates(metric: .restingHeartRate, series: series, referenceDate: referenceDate, calendar: calendar)

        let today = states.last!
        XCTAssertEqual(today.date, day(0))
        XCTAssertNotNil(today.baseline)
        XCTAssertTrue(today.baseline!.isReliable)
        XCTAssertNotNil(today.deviation)
        XCTAssertGreaterThan(today.deviation!, 1.5)
        XCTAssertEqual(today.percentile ?? -1, 100, accuracy: 0.001)
    }

    func test_metricStates_daysAbnormalStreakIncrementsAndResets() {
        var series: [Date: Double] = [:]
        for offset in -52...(-8) {
            series[day(offset)] = 60 // stable baseline, SD == 0 makes any change infinitely abnormal once nonzero variance exists
        }
        // Give the baseline a little real variance so zScore is finite.
        series[day(-10)] = 62
        series[day(-9)] = 58

        // Recent window: normal, normal, abnormal, abnormal, abnormal, normal, abnormal
        series[day(-6)] = 60
        series[day(-5)] = 60
        series[day(-4)] = 90
        series[day(-3)] = 90
        series[day(-2)] = 90
        series[day(-1)] = 60
        series[day(0)] = 90

        let engine = PersonalBaselineEngine()
        let states = engine.metricStates(metric: .restingHeartRate, series: series, referenceDate: referenceDate, calendar: calendar)
        let byDate = Dictionary(uniqueKeysWithValues: states.map { ($0.date, $0) })

        XCTAssertEqual(byDate[day(-6)]?.daysAbnormal, 0)
        XCTAssertEqual(byDate[day(-4)]?.daysAbnormal, 1)
        XCTAssertEqual(byDate[day(-3)]?.daysAbnormal, 2)
        XCTAssertEqual(byDate[day(-2)]?.daysAbnormal, 3)
        XCTAssertEqual(byDate[day(-1)]?.daysAbnormal, 0, "A normal day should reset the streak")
        XCTAssertEqual(byDate[day(0)]?.daysAbnormal, 1, "A new abnormal day starts a fresh streak")
    }

    func test_metricStates_skipsDaysWithoutData() {
        var series: [Date: Double] = [:]
        for offset in -52...(-8) {
            series[day(offset)] = 60
        }
        // Only 3 of the last 7 days have data.
        series[day(-2)] = 61
        series[day(-1)] = 59
        series[day(0)] = 60

        let engine = PersonalBaselineEngine()
        let states = engine.metricStates(metric: .steps, series: series, referenceDate: referenceDate, calendar: calendar)

        XCTAssertEqual(states.count, 3)
    }

    // MARK: - Trend

    func test_trend_sustainedRisingSequenceIsDetected() {
        var series: [Date: Double] = [:]
        let values: [Double] = [50, 53, 55, 58, 61, 64, 67]
        for (index, value) in values.enumerated() {
            series[day(-6 + index)] = value
        }

        let trend = PersonalBaselineEngine.trend(series: series, endingAt: day(0), windowDays: 7, calendar: calendar, consistencyThreshold: 0.65)

        XCTAssertNotNil(trend)
        XCTAssertEqual(trend!.direction, .rising)
        XCTAssertTrue(trend!.isSustained)
        XCTAssertGreaterThan(trend!.slopePerDay, 0)
    }

    func test_trend_noisyFlatSequenceIsNotSustained() {
        var series: [Date: Double] = [:]
        let values: [Double] = [60, 63, 58, 62, 59, 63, 60]
        for (index, value) in values.enumerated() {
            series[day(-6 + index)] = value
        }

        let trend = PersonalBaselineEngine.trend(series: series, endingAt: day(0), windowDays: 7, calendar: calendar, consistencyThreshold: 0.65)

        XCTAssertNotNil(trend)
        XCTAssertFalse(trend!.isSustained, "Zig-zagging noise shouldn't be reported as a sustained trend")
    }

    func test_trend_returnsNilWithInsufficientPoints() {
        var series: [Date: Double] = [:]
        series[day(0)] = 60
        series[day(-1)] = 61

        let trend = PersonalBaselineEngine.trend(series: series, endingAt: day(0), windowDays: 7, calendar: calendar, consistencyThreshold: 0.65)
        XCTAssertNil(trend)
    }
}

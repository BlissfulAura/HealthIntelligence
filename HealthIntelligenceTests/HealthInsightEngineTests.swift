//
//  HealthInsightEngineTests.swift
//  HealthIntelligenceTests
//
//  End-to-end coverage: given a synthetic history of DailyHealthSnapshots,
//  the full pipeline (baseline -> signal -> pattern -> insight) should stay
//  silent on an unremarkable history and speak up on a genuinely elevated
//  one — exercising all four stages together rather than in isolation.
//

import XCTest
@testable import HealthIntelligence

final class HealthInsightEngineTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: referenceDate))!
    }

    func test_stableHistoryProducesNoInsights() {
        var snapshots: [DailyHealthSnapshot] = []
        for offset in -59...0 {
            snapshots.append(DailyHealthSnapshot(
                date: day(offset),
                restingHeartRate: 60,
                sleepDuration: 7.5 * 3600,
                steps: 8000,
                activeEnergy: 400,
                strainScore: nil
            ))
        }

        let engine = HealthInsightEngine()
        let insights = engine.generateInsights(from: snapshots, referenceDate: referenceDate, calendar: calendar)

        XCTAssertTrue(insights.isEmpty, "An unremarkable, stable history shouldn't manufacture insights")
    }

    func test_sustainedRHRElevationProducesAnInsight() {
        var snapshots: [DailyHealthSnapshot] = []
        for offset in -59...(-8) {
            // Small realistic day-to-day noise so the baseline has genuine
            // variance instead of being perfectly flat.
            let noise = (offset % 2 == 0) ? 1.0 : -1.0
            snapshots.append(DailyHealthSnapshot(
                date: day(offset),
                restingHeartRate: 60 + noise,
                sleepDuration: 7.5 * 3600,
                steps: 8000,
                activeEnergy: 400,
                strainScore: nil
            ))
        }
        // Recent week: RHR climbs steadily and stays elevated.
        let recentRHR: [Double] = [63, 65, 67, 69, 71, 73, 75]
        for (index, value) in recentRHR.enumerated() {
            snapshots.append(DailyHealthSnapshot(
                date: day(-6 + index),
                restingHeartRate: value,
                sleepDuration: 7.5 * 3600,
                steps: 8000,
                activeEnergy: 400,
                strainScore: nil
            ))
        }

        let engine = HealthInsightEngine()
        let insights = engine.generateInsights(from: snapshots, referenceDate: referenceDate, calendar: calendar)

        XCTAssertFalse(insights.isEmpty, "A sustained, meaningful RHR climb should surface at least one insight")
        XCTAssertTrue(insights.allSatisfy { !$0.title.isEmpty && !$0.narrative.isEmpty })
        XCTAssertTrue(insights.contains { $0.narrative.localizedCaseInsensitiveContains("resting heart rate") })
    }

    func test_insightsAreSortedMostSevereFirst() {
        var snapshots: [DailyHealthSnapshot] = []
        for offset in -59...(-8) {
            let noise = (offset % 2 == 0) ? 1.0 : -1.0
            snapshots.append(DailyHealthSnapshot(
                date: day(offset),
                restingHeartRate: 60 + noise,
                sleepDuration: 7.5 * 3600,
                steps: 8000 + noise * 100,
                activeEnergy: 400,
                strainScore: nil
            ))
        }
        for offset in -7...0 {
            snapshots.append(DailyHealthSnapshot(
                date: day(offset),
                restingHeartRate: 78, // sharply, consistently elevated
                sleepDuration: 7.5 * 3600,
                steps: 8000,
                activeEnergy: 400,
                strainScore: nil
            ))
        }

        let engine = HealthInsightEngine()
        let insights = engine.generateInsights(from: snapshots, referenceDate: referenceDate, calendar: calendar)

        guard insights.count > 1 else { return } // nothing to order if only one/zero
        for i in 1..<insights.count {
            XCTAssertGreaterThanOrEqual(insights[i - 1].severity, insights[i].severity)
        }
    }

    func test_insightsCarryEvidenceAndSupportingStatesForTheFeedDetailView() {
        var snapshots: [DailyHealthSnapshot] = []
        for offset in -59...(-8) {
            let noise = (offset % 2 == 0) ? 1.0 : -1.0
            snapshots.append(DailyHealthSnapshot(
                date: day(offset), restingHeartRate: 60 + noise, sleepDuration: 7.5 * 3600,
                steps: 8000, activeEnergy: 400, strainScore: nil
            ))
        }
        for (index, value) in [63.0, 65, 67, 69, 71, 73, 75].enumerated() {
            snapshots.append(DailyHealthSnapshot(
                date: day(-6 + index), restingHeartRate: value, sleepDuration: 7.5 * 3600,
                steps: 8000, activeEnergy: 400, strainScore: nil
            ))
        }

        let insights = HealthInsightEngine().generateInsights(from: snapshots, referenceDate: referenceDate, calendar: calendar)

        XCTAssertFalse(insights.isEmpty)
        // Every insight should carry both the always-visible evidence
        // lines and the fuller supporting-states detail for an expandable
        // "why am I seeing this" view — never one without the other.
        for insight in insights {
            XCTAssertFalse(insight.evidence.isEmpty, "\(insight.title) has no evidence")
            XCTAssertFalse(insight.supportingStates.isEmpty, "\(insight.title) has no supporting states")
        }
    }

    func test_favorableSustainedTrendSurfacesAsItsOwnLowSeverityInsight() {
        var snapshots: [DailyHealthSnapshot] = []
        for offset in -59...(-8) {
            let noise = (offset % 2 == 0) ? 1.0 : -1.0
            snapshots.append(DailyHealthSnapshot(
                date: day(offset), restingHeartRate: 65 + noise, sleepDuration: 7.5 * 3600,
                steps: 8000, activeEnergy: 400, strainScore: nil
            ))
        }
        // Recent week: RHR falls steadily — favorable direction (lower RHR
        // is the "good" direction), should read as reassurance, not alarm.
        for (index, value) in [64.0, 62, 60, 58, 56, 54, 52].enumerated() {
            snapshots.append(DailyHealthSnapshot(
                date: day(-6 + index), restingHeartRate: value, sleepDuration: 7.5 * 3600,
                steps: 8000, activeEnergy: 400, strainScore: nil
            ))
        }

        let insights = HealthInsightEngine().generateInsights(from: snapshots, referenceDate: referenceDate, calendar: calendar)

        let trendInsight = insights.first { $0.title.localizedCaseInsensitiveContains("trending downward") }
        XCTAssertNotNil(trendInsight, "A favorable, sustained RHR decline should surface as its own insight")
        XCTAssertEqual(trendInsight?.severity, .info, "A favorable trend shouldn't be presented as a concern")
    }

    func test_baselineDeviationHeadlineUsesNaturalPossessiveDayPhrasing() {
        var snapshots: [DailyHealthSnapshot] = []
        for offset in -59...(-1) {
            // A little real variance so the baseline has a nonzero SD — a
            // perfectly flat history makes zScore() return nil, which
            // silently suppresses the baseline-deviation signal.
            let noise = (offset % 2 == 0) ? 1.0 : -1.0
            snapshots.append(DailyHealthSnapshot(
                date: day(offset), restingHeartRate: 60 + noise, sleepDuration: 7.5 * 3600,
                steps: 8000, activeEnergy: 400, strainScore: nil
            ))
        }
        // Only today is a spike, and today has no reliable trend history of
        // its own, so this should read as a plain baseline-deviation
        // headline: "Today's resting heart rate was unusually high for you."
        snapshots.append(DailyHealthSnapshot(
            date: day(0), restingHeartRate: 90, sleepDuration: 7.5 * 3600,
            steps: 8000, activeEnergy: 400, strainScore: nil
        ))

        let insights = HealthInsightEngine().generateInsights(from: snapshots, referenceDate: referenceDate, calendar: calendar)

        XCTAssertTrue(insights.contains { $0.title.hasPrefix("Today's") }, "Expected a \"Today's ...\" headline, got: \(insights.map(\.title))")
    }

    func test_garminOnlyMetricsLikeHRVAndBodyBatteryFeedTheSamePipelineAsHealthKitMetrics() {
        var snapshots: [DailyHealthSnapshot] = []
        for offset in -59...(-8) {
            let noise = (offset % 2 == 0) ? 1.0 : -1.0
            snapshots.append(DailyHealthSnapshot(
                date: day(offset), restingHeartRate: 60, sleepDuration: 7.5 * 3600,
                steps: 8000, activeEnergy: 400, strainScore: nil,
                heartRateVariability: 50 + noise, vo2Max: 45, respirationRate: 14 + noise,
                bloodOxygen: 0.97, stress: 25 + noise, bodyBattery: 70 + noise
            ))
        }
        // Recent week: HRV (a favorable-when-rising metric) and Body Battery
        // both drop sharply and stay down — a classic "underrecovered"
        // picture that only the Garmin-sourced metrics can tell.
        for (index, offset) in (-6...0).enumerated() {
            snapshots.append(DailyHealthSnapshot(
                date: day(offset), restingHeartRate: 60, sleepDuration: 7.5 * 3600,
                steps: 8000, activeEnergy: 400, strainScore: nil,
                heartRateVariability: 50 - Double(index) * 4, vo2Max: 45, respirationRate: 14,
                bloodOxygen: 0.97, stress: 25, bodyBattery: 70 - Double(index) * 4
            ))
        }

        let insights = HealthInsightEngine().generateInsights(from: snapshots, referenceDate: referenceDate, calendar: calendar)

        // Both unfavorable trends at once may either surface as their own
        // standalone insights or get folded into a single "emerging
        // deterioration" pattern (see HealthPatternDetector) — either way,
        // both Garmin-only metrics must be traceable somewhere in the feed,
        // not silently dropped the way they were before this metric was
        // wired into the pipeline.
        let combinedText = insights
            .map { [$0.title, $0.narrative, $0.evidence.joined(separator: " ")].joined(separator: " ") }
            .joined(separator: " | ")

        XCTAssertTrue(
            combinedText.localizedCaseInsensitiveContains("heart rate variability"),
            "Expected HRV's decline to be traceable in the feed, got: \(insights.map(\.title))"
        )
        XCTAssertTrue(
            combinedText.localizedCaseInsensitiveContains("body battery"),
            "Expected Body Battery's decline to be traceable in the feed, got: \(insights.map(\.title))"
        )
    }
}

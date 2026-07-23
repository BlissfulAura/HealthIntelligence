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
}

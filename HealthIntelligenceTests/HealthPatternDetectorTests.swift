//
//  HealthPatternDetectorTests.swift
//  HealthIntelligenceTests
//
//  Coverage for grouping signals into patterns: emerging deterioration
//  needs multiple simultaneous unfavorable trend signals (not just one),
//  and the single-signal wrapper patterns (recovery debt, unusual load,
//  bounce-back) only fire for their matching signal kind.
//

import XCTest
@testable import HealthIntelligence

final class HealthPatternDetectorTests: XCTestCase {
    private let detector = HealthPatternDetector()
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func trendSignal(metric: IntelligenceMetric, severity: SignalSeverity, confidence: Double = 0.9) -> HealthSignal {
        let state = MetricState(
            metric: metric,
            date: referenceDate,
            currentValue: 60,
            baseline: MetricBaseline(mean: 60, standardDeviation: 5, sampleCount: 20),
            deviation: 1.0,
            percentile: nil,
            trend: TrendResult(direction: .rising, slopePerDay: 0.5, consistency: confidence, isSustained: true),
            daysAbnormal: 1
        )
        return HealthSignal(kind: .sustainedTrend, date: referenceDate, severity: severity, confidence: confidence, supportingStates: [state], explanation: "test")
    }

    private func signal(kind: HealthSignalKind, severity: SignalSeverity = .moderate, confidence: Double = 0.8) -> HealthSignal {
        HealthSignal(kind: kind, date: referenceDate, severity: severity, confidence: confidence, supportingStates: [], explanation: "test")
    }

    // MARK: - Emerging deterioration

    func test_detectEmergingDeterioration_nilWithFewerThanTwoQualifyingSignals() {
        let onlyOne = [trendSignal(metric: .restingHeartRate, severity: .moderate)]
        XCTAssertNil(detector.detectEmergingDeterioration(trendSignals: onlyOne, date: referenceDate))
    }

    func test_detectEmergingDeterioration_ignoresLowSeveritySignals() {
        // Two signals, but both below .moderate (e.g. favorable-direction
        // trends), shouldn't count as deterioration.
        let favorable = [
            trendSignal(metric: .sleepDuration, severity: .info),
            trendSignal(metric: .steps, severity: .info),
        ]
        XCTAssertNil(detector.detectEmergingDeterioration(trendSignals: favorable, date: referenceDate))
    }

    func test_detectEmergingDeterioration_firesWithTwoOrMoreUnfavorableSignals() {
        let unfavorable = [
            trendSignal(metric: .restingHeartRate, severity: .moderate),
            trendSignal(metric: .sleepDuration, severity: .moderate),
        ]
        let pattern = detector.detectEmergingDeterioration(trendSignals: unfavorable, date: referenceDate)
        XCTAssertNotNil(pattern)
        XCTAssertEqual(pattern?.kind, .emergingDeterioration)
        XCTAssertEqual(pattern?.signals.count, 2)
    }

    // MARK: - Single-signal wrapper patterns

    func test_detectRecoveryDebt_nilForWrongKindOrMissingSignal() {
        XCTAssertNil(detector.detectRecoveryDebt(from: nil, date: referenceDate))
        XCTAssertNil(detector.detectRecoveryDebt(from: signal(kind: .unusualPhysiologicalLoad), date: referenceDate))
    }

    func test_detectRecoveryDebt_wrapsMatchingSignal() {
        let pattern = detector.detectRecoveryDebt(from: signal(kind: .recoveryDebt), date: referenceDate)
        XCTAssertNotNil(pattern)
        XCTAssertEqual(pattern?.kind, .recoveryDebt)
    }

    func test_detectUnusualPhysiologicalLoad_nilForWrongKind() {
        XCTAssertNil(detector.detectUnusualPhysiologicalLoad(from: signal(kind: .recoveryDebt), date: referenceDate))
    }

    func test_detectUnusualPhysiologicalLoad_wrapsMatchingSignal() {
        let pattern = detector.detectUnusualPhysiologicalLoad(from: signal(kind: .unusualPhysiologicalLoad), date: referenceDate)
        XCTAssertNotNil(pattern)
        XCTAssertEqual(pattern?.kind, .unusualPhysiologicalLoad)
    }

    func test_detectBounceBack_filtersToOnlyBounceBackSignals() {
        let mixed = [signal(kind: .recoveryDebt), signal(kind: .bounceBack), signal(kind: .unusualPhysiologicalLoad)]
        let pattern = detector.detectBounceBack(from: mixed, date: referenceDate)
        XCTAssertNotNil(pattern)
        XCTAssertEqual(pattern?.signals.count, 1)
    }

    func test_detectBounceBack_nilWithNoBounceBackSignals() {
        let noneMatching = [signal(kind: .recoveryDebt), signal(kind: .unusualPhysiologicalLoad)]
        XCTAssertNil(detector.detectBounceBack(from: noneMatching, date: referenceDate))
    }
}

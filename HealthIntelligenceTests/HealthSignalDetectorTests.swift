//
//  HealthSignalDetectorTests.swift
//  HealthIntelligenceTests
//
//  Coverage for each signal detector: that it requires a reliable baseline
//  before speaking up, that severity scales with deviation magnitude, and
//  that each capability's specific gating logic (unfavorable direction,
//  prior abnormal streak, activity explaining a load, elevated-strain
//  streak) behaves as documented.
//

import XCTest
@testable import HealthIntelligence

final class HealthSignalDetectorTests: XCTestCase {
    private let detector = HealthSignalDetector()
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(
        metric: IntelligenceMetric,
        deviation: Double?,
        sampleCount: Int = 20,
        daysAbnormal: Int = 0,
        trend: TrendResult? = nil,
        value: Double = 60
    ) -> MetricState {
        let baseline: MetricBaseline? = sampleCount > 0
            ? MetricBaseline(mean: 60, standardDeviation: 5, sampleCount: sampleCount)
            : nil
        return MetricState(
            metric: metric,
            date: referenceDate,
            currentValue: value,
            baseline: baseline,
            deviation: deviation,
            percentile: nil,
            trend: trend,
            daysAbnormal: daysAbnormal
        )
    }

    // MARK: - Baseline deviation

    func test_detectBaselineDeviation_nilWithoutReliableBaseline() {
        let unreliable = state(metric: .restingHeartRate, deviation: 3.0, sampleCount: MetricBaseline.minimumReliableSampleCount - 1)
        XCTAssertNil(detector.detectBaselineDeviation(unreliable))
    }

    func test_detectBaselineDeviation_nilBelowThreshold() {
        let mild = state(metric: .restingHeartRate, deviation: 0.8)
        XCTAssertNil(detector.detectBaselineDeviation(mild))
    }

    func test_detectBaselineDeviation_severityScalesWithMagnitude() {
        XCTAssertEqual(detector.detectBaselineDeviation(state(metric: .restingHeartRate, deviation: 1.7))?.severity, .mild)
        XCTAssertEqual(detector.detectBaselineDeviation(state(metric: .restingHeartRate, deviation: 2.5))?.severity, .moderate)
        XCTAssertEqual(detector.detectBaselineDeviation(state(metric: .restingHeartRate, deviation: 3.5))?.severity, .significant)
    }

    func test_detectBaselineDeviation_worksForNegativeDeviationToo() {
        let signal = detector.detectBaselineDeviation(state(metric: .sleepDuration, deviation: -2.2))
        XCTAssertNotNil(signal)
        XCTAssertTrue(signal!.explanation.contains("below"))
    }

    // MARK: - Sustained trend

    func test_detectSustainedTrend_nilWhenNotSustained() {
        let notSustained = TrendResult(direction: .rising, slopePerDay: 0.2, consistency: 0.4, isSustained: false)
        XCTAssertNil(detector.detectSustainedTrend(state(metric: .restingHeartRate, deviation: 0, trend: notSustained)))
    }

    func test_detectSustainedTrend_unfavorableDirectionIsModerateSeverity() {
        // Rising RHR is unfavorable.
        let rising = TrendResult(direction: .rising, slopePerDay: 0.5, consistency: 0.9, isSustained: true)
        let signal = detector.detectSustainedTrend(state(metric: .restingHeartRate, deviation: 0.5, trend: rising))
        XCTAssertEqual(signal?.severity, .moderate)
    }

    func test_detectSustainedTrend_favorableDirectionIsInfoSeverity() {
        // Rising sleep duration is favorable, not a concern.
        let rising = TrendResult(direction: .rising, slopePerDay: 300, consistency: 0.9, isSustained: true)
        let signal = detector.detectSustainedTrend(state(metric: .sleepDuration, deviation: 0.5, trend: rising))
        XCTAssertEqual(signal?.severity, .info)
    }

    // MARK: - Bounce-back

    func test_detectBounceBack_requiresPriorAbnormalStreak() {
        let previousBriefly = state(metric: .restingHeartRate, deviation: 2.0, daysAbnormal: 1)
        let current = state(metric: .restingHeartRate, deviation: 0.2)
        XCTAssertNil(detector.detectBounceBack(previous: previousBriefly, current: current))
    }

    func test_detectBounceBack_requiresCurrentBackWithinNormalRange() {
        let previous = state(metric: .restingHeartRate, deviation: 2.0, daysAbnormal: 3)
        let stillElevated = state(metric: .restingHeartRate, deviation: 1.8)
        XCTAssertNil(detector.detectBounceBack(previous: previous, current: stillElevated))
    }

    func test_detectBounceBack_succeedsAfterStreakAndReturnToNormal() {
        let previous = state(metric: .restingHeartRate, deviation: 2.0, daysAbnormal: 3)
        let recovered = state(metric: .restingHeartRate, deviation: 0.3)
        let signal = detector.detectBounceBack(previous: previous, current: recovered)
        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.kind, .bounceBack)
    }

    // MARK: - Unusual physiological load

    func test_detectUnusualPhysiologicalLoad_nilWhenActivityAlsoElevated() {
        let elevatedRHR = state(metric: .restingHeartRate, deviation: 2.0)
        let elevatedActivity = state(metric: .activeEnergy, deviation: 1.5)
        XCTAssertNil(detector.detectUnusualPhysiologicalLoad(rhrOrStrain: elevatedRHR, activity: elevatedActivity))
    }

    func test_detectUnusualPhysiologicalLoad_signalWhenActivityNormal() {
        let elevatedRHR = state(metric: .restingHeartRate, deviation: 2.0)
        let normalActivity = state(metric: .activeEnergy, deviation: 0.1)
        let signal = detector.detectUnusualPhysiologicalLoad(rhrOrStrain: elevatedRHR, activity: normalActivity)
        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.kind, .unusualPhysiologicalLoad)
    }

    func test_detectUnusualPhysiologicalLoad_signalWhenNoActivityDataAtAll() {
        let elevatedRHR = state(metric: .restingHeartRate, deviation: 2.0)
        let signal = detector.detectUnusualPhysiologicalLoad(rhrOrStrain: elevatedRHR, activity: nil)
        XCTAssertNotNil(signal)
    }

    // MARK: - Recovery debt

    func test_detectRecoveryDebt_requiresBothElevatedStrainStreakAndElevatedRHR() {
        let currentRHR = state(metric: .restingHeartRate, deviation: 1.2)
        let oneElevatedStrainDay = [state(metric: .strainScore, deviation: 1.4)]
        XCTAssertNil(detector.detectRecoveryDebt(recentStrainStates: oneElevatedStrainDay, currentRHRState: currentRHR))

        let twoElevatedStrainDays = [
            state(metric: .strainScore, deviation: 1.4),
            state(metric: .strainScore, deviation: 1.6),
        ]
        XCTAssertNotNil(detector.detectRecoveryDebt(recentStrainStates: twoElevatedStrainDays, currentRHRState: currentRHR))
    }

    func test_detectRecoveryDebt_nilWhenRHRHasAlreadyNormalized() {
        let normalizedRHR = state(metric: .restingHeartRate, deviation: 0.2)
        let elevatedStrainDays = [
            state(metric: .strainScore, deviation: 1.4),
            state(metric: .strainScore, deviation: 1.6),
        ]
        XCTAssertNil(detector.detectRecoveryDebt(recentStrainStates: elevatedStrainDays, currentRHRState: normalizedRHR))
    }
}

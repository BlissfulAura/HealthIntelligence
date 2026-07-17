//
//  HealthAnalyzer.swift
//  HealthIntelligence
//
//  Deterministic analysis of health data. Produces facts (a resting heart
//  rate is X% above baseline), not conclusions ("you are stressed").
//
//  Named "Strain" rather than "Stress" deliberately: Garmin syncs a limited
//  subset of its data into Apple Health, and HRV is not reliably part of
//  that subset. Without HRV, autonomic/psychological stress can't be
//  estimated responsibly — "strain" (how physiologically taxed the user
//  appears from heart rate and activity load alone) is what the available
//  data can actually support.
//
//  This file currently only establishes the output shapes and the two or
//  three calculations simple enough to be unambiguously correct (averages,
//  percentage deviation from a personal baseline). The real Strain/Sleep/
//  Activity scoring models — rolling baselines, trend detection, sleep
//  fragmentation, recent load — are future work and should slot into the
//  `analyze...` functions below without changing their signatures.
//

import Foundation

// MARK: - Analysis outputs

struct StrainAnalysis {
    let restingHeartRate: Double?
    let baselineRestingHeartRate: Double?
    let percentageDeviationFromBaseline: Double?

    // Future: recent physical load (active energy trend), elevated
    // non-exercise heart rate, and a combined strain score derived from
    // deviation across multiple signals rather than resting HR alone.
}

struct SleepAnalysis {
    let session: SleepSession?
    let totalTimeAsleep: TimeInterval?
    let totalTimeInBed: TimeInterval?
    let stageBreakdown: [SleepStage: TimeInterval]

    // Future: duration/fragmentation/stage-distribution relative to the
    // user's personal baseline, not fixed sleep-hygiene targets.
}

struct ActivityAnalysis {
    let totalStepsToday: Double
    let totalActiveEnergyToday: Double
    let baselineAverageDailySteps: Double?
    let percentageDeviationFromBaseline: Double?

    // Future: incorporate active-energy baseline and exercise minutes into
    // a combined activeness measure, not steps alone.
}

// MARK: - Analyzer

struct HealthAnalyzer {
    func analyzeStrain(
        todayRestingHeartRate: HealthMetricSample?,
        baselineRestingHeartRateSamples: [HealthMetricSample]
    ) -> StrainAnalysis {
        let baseline = Self.average(baselineRestingHeartRateSamples.map(\.value))
        let today = todayRestingHeartRate?.value
        return StrainAnalysis(
            restingHeartRate: today,
            baselineRestingHeartRate: baseline,
            percentageDeviationFromBaseline: Self.percentageDeviation(value: today, from: baseline)
        )
    }

    func analyzeSleep(mostRecentSession: SleepSession?) -> SleepAnalysis {
        guard let session = mostRecentSession else {
            return SleepAnalysis(session: nil, totalTimeAsleep: nil, totalTimeInBed: nil, stageBreakdown: [:])
        }

        var breakdown: [SleepStage: TimeInterval] = [:]
        for stage in SleepStage.allCases {
            let duration = session.totalDuration(for: stage)
            if duration > 0 { breakdown[stage] = duration }
        }

        return SleepAnalysis(
            session: session,
            totalTimeAsleep: session.totalTimeAsleep,
            totalTimeInBed: session.timeSpan,
            stageBreakdown: breakdown
        )
    }

    func analyzeActivity(
        todaySteps: [HealthMetricSample],
        todayActiveEnergy: [HealthMetricSample],
        baselineDailySteps: [Double]
    ) -> ActivityAnalysis {
        let totalSteps = todaySteps.reduce(0) { $0 + $1.value }
        let totalActiveEnergy = todayActiveEnergy.reduce(0) { $0 + $1.value }
        let baseline = Self.average(baselineDailySteps)

        return ActivityAnalysis(
            totalStepsToday: totalSteps,
            totalActiveEnergyToday: totalActiveEnergy,
            baselineAverageDailySteps: baseline,
            percentageDeviationFromBaseline: Self.percentageDeviation(value: totalSteps, from: baseline)
        )
    }

    // MARK: - Shared math

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentageDeviation(value: Double?, from baseline: Double?) -> Double? {
        guard let value, let baseline, baseline != 0 else { return nil }
        return ((value - baseline) / baseline) * 100
    }
}

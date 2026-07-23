//
//  MetricState.swift
//  HealthIntelligence
//
//  Domain models for the longitudinal intelligence pipeline:
//
//      HealthKit -> HealthAnalyzer -> HealthHistoryBuilder ->
//      PersonalBaselineEngine -> HealthSignalDetector ->
//      HealthPatternDetector -> HealthInsightEngine
//
//  See HealthInsight.swift for the full pipeline explanation, what's
//  implemented vs. deferred, and minimum data requirements. This file only
//  holds the pure value types the pipeline passes between stages; the math
//  that produces them lives in PersonalBaselineEngine.swift.
//

import Foundation

/// The metrics the intelligence layer tracks longitudinally. Deliberately a
/// small, curated set — only things the app can compute reliably from what
/// HealthKit (via Garmin or Apple) actually provides, not an aspirational
/// list. Sleep stages and workouts feed the existing per-day analyses but
/// aren't tracked as their own longitudinal series yet.
enum IntelligenceMetric: String, CaseIterable, Sendable {
    case restingHeartRate
    case sleepDuration
    case steps
    case activeEnergy
    case strainScore

    var displayName: String {
        switch self {
        case .restingHeartRate: "Resting Heart Rate"
        case .sleepDuration: "Sleep Duration"
        case .steps: "Steps"
        case .activeEnergy: "Active Energy"
        case .strainScore: "Strain"
        }
    }

    /// Which direction of change is unfavorable for this metric. Needed
    /// because "higher" means opposite things for, say, resting heart rate
    /// (bad) vs. sleep duration (bad only when *lower*). Used by the signal
    /// layer to judge a trend, not by this layer itself — MetricState stays
    /// a neutral statistical snapshot with no value judgment baked in.
    var unfavorableDirection: TrendDirection {
        switch self {
        case .restingHeartRate, .strainScore: .rising
        case .sleepDuration, .steps, .activeEnergy: .falling
        }
    }
}

enum TrendDirection: Sendable {
    case rising
    case falling
    case stable
}

/// A personal statistical baseline for one metric, computed from the user's
/// own history — never a population/universal reference range. Uses
/// population (not sample-corrected) standard deviation; a reasonable
/// simplification once `sampleCount` is in the dozens, which is where
/// `isReliable` already gates its use.
struct MetricBaseline: Sendable {
    let mean: Double
    let standardDeviation: Double
    let sampleCount: Int

    /// Below this many days of history, a baseline exists mathematically
    /// but isn't trustworthy enough to drive a signal from. See
    /// HealthSignalDetector, which is where this gate is actually enforced.
    static let minimumReliableSampleCount = 14

    var isReliable: Bool { sampleCount >= Self.minimumReliableSampleCount }

    func zScore(for value: Double) -> Double? {
        guard standardDeviation > 0 else { return nil }
        return (value - mean) / standardDeviation
    }
}

/// The result of fitting a simple trend line over a recent window.
struct TrendResult: Sendable {
    let direction: TrendDirection
    /// Change per day implied by a least-squares fit over the window.
    let slopePerDay: Double
    /// Fraction of day-over-day changes whose sign agrees with the overall
    /// slope's sign — how "clean" the trend is vs. noisy zig-zagging.
    let consistency: Double
    /// True only when direction is not `.stable` AND the trend is
    /// consistent enough to be more than day-to-day noise. This is the
    /// "sustained trend vs. normal noise" distinction.
    let isSustained: Bool
}

/// One metric, on one day, with everything the signal/pattern layers need
/// to reason about it: current value, personal baseline, deviation,
/// historical percentile, trend, and how long it's been abnormal.
struct MetricState: Sendable {
    let metric: IntelligenceMetric
    let date: Date
    let currentValue: Double
    /// `nil` if there isn't enough history yet to compute one at all
    /// (fewer than 3 prior days — see PersonalBaselineEngine).
    let baseline: MetricBaseline?
    /// Standard deviations from the personal baseline. `nil` without a
    /// baseline, or when the baseline has zero variance.
    let deviation: Double?
    /// Empirical percentile (0...100) of `currentValue` within the
    /// baseline's own historical values — a rank, not a normal-distribution
    /// assumption.
    let percentile: Double?
    /// `nil` if there isn't enough recent history to fit a trend.
    let trend: TrendResult?
    /// Consecutive days (including this one) the metric's deviation has
    /// been at or beyond the abnormality threshold, in either direction.
    /// Resets on any day without data or within-normal-range.
    let daysAbnormal: Int
}

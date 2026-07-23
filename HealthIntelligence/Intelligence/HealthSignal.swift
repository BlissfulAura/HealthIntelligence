//
//  HealthSignal.swift
//  HealthIntelligence
//
//  Atomic, evidence-backed observations derived from one or two
//  MetricStates. Signals answer "is this specific thing true right now";
//  HealthPattern groups related signals into a bigger story; HealthInsight
//  turns that into user-facing language. See HealthInsight.swift for the
//  full pipeline picture.
//
//  Pipeline stage: Personal Baselines -> [this] -> Pattern Detection -> ...
//
//  Pure and HealthKit-independent — every detector here takes already-built
//  MetricStates, so it's directly unit-testable with synthetic data (see
//  HealthSignalDetectorTests).
//

import Foundation

enum SignalSeverity: Int, Comparable, Sendable {
    case info
    case mild
    case moderate
    case significant

    static func < (lhs: SignalSeverity, rhs: SignalSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .info: "Info"
        case .mild: "Mild"
        case .moderate: "Moderate"
        case .significant: "Significant"
        }
    }
}

enum HealthSignalKind: Sendable {
    case baselineDeviation
    case sustainedTrend
    case bounceBack
    case unusualPhysiologicalLoad
    case recoveryDebt
}

struct HealthSignal: Identifiable, Sendable {
    let id = UUID()
    let kind: HealthSignalKind
    let date: Date
    let severity: SignalSeverity
    /// 0...1. Reflects how much data backs this signal (baseline sample
    /// count, trend consistency) — not how large the effect looks.
    let confidence: Double
    let supportingStates: [MetricState]
    let explanation: String
}

struct HealthSignalDetector {
    /// Below this, a baseline deviation isn't called meaningful — matches
    /// PersonalBaselineEngine's default `abnormalityThreshold` so the two
    /// stay in sync even though this layer doesn't depend on that one.
    var deviationThreshold: Double = 1.5
    /// Threshold for "back within normal range" in a bounce-back check —
    /// deliberately looser than `deviationThreshold` so a metric doesn't
    /// have to land exactly on the mean to count as recovered.
    var normalRangeThreshold: Double = 1.0
    /// Minimum prior abnormal-day streak before a return to normal counts
    /// as a bounce-back worth mentioning (one noisy day isn't a story).
    var minimumAbnormalStreakForBounceBack: Int = 2
    /// Minimum days of recent elevated strain before "recovery debt" is
    /// considered, distinct from a single hard day.
    var minimumElevatedStrainDaysForRecoveryDebt: Int = 2

    init() {}

    /// Capability 1 — meaningful baseline deviation.
    func detectBaselineDeviation(_ state: MetricState) -> HealthSignal? {
        guard let baseline = state.baseline, baseline.isReliable,
            let deviation = state.deviation, abs(deviation) >= deviationThreshold else { return nil }

        let direction = deviation > 0 ? "above" : "below"
        return HealthSignal(
            kind: .baselineDeviation,
            date: state.date,
            severity: Self.severity(forAbsoluteZ: abs(deviation)),
            confidence: Self.confidence(for: baseline),
            supportingStates: [state],
            explanation: "\(state.metric.displayName) is \(Self.formatted(abs(deviation)))\u{03C3} \(direction) your personal baseline of \(Self.formatted(baseline.mean))."
        )
    }

    /// Capability 2 — sustained trend vs. day-to-day noise.
    func detectSustainedTrend(_ state: MetricState) -> HealthSignal? {
        guard let trend = state.trend, trend.isSustained,
            let baseline = state.baseline, baseline.isReliable else { return nil }

        let directionWord = trend.direction == .rising ? "rising" : "falling"
        let isUnfavorable = trend.direction == state.metric.unfavorableDirection
        return HealthSignal(
            kind: .sustainedTrend,
            date: state.date,
            severity: isUnfavorable ? .moderate : .info,
            confidence: trend.consistency,
            supportingStates: [state],
            explanation: "\(state.metric.displayName) has been consistently \(directionWord) over the last several days, not just noisy day-to-day variation."
        )
    }

    /// Capability 11 — bounce-back: was abnormal for a while, now isn't.
    func detectBounceBack(previous: MetricState, current: MetricState) -> HealthSignal? {
        guard previous.daysAbnormal >= minimumAbnormalStreakForBounceBack,
            let deviation = current.deviation, abs(deviation) < normalRangeThreshold else { return nil }

        return HealthSignal(
            kind: .bounceBack,
            date: current.date,
            severity: .info,
            confidence: current.baseline.map(Self.confidence) ?? 0.4,
            supportingStates: [previous, current],
            explanation: "\(current.metric.displayName) has returned toward your personal baseline after \(previous.daysAbnormal) day(s) of deviation."
        )
    }

    /// Capability 8 — unusual physiological load without recorded activity
    /// to explain it.
    func detectUnusualPhysiologicalLoad(rhrOrStrain: MetricState, activity: MetricState?) -> HealthSignal? {
        guard let baseline = rhrOrStrain.baseline, baseline.isReliable,
            let deviation = rhrOrStrain.deviation, deviation >= deviationThreshold else { return nil }

        // Only "unusual" when activity is NOT also elevated — otherwise the
        // rise is plausibly just exercise, which belongs to Strain/Activity,
        // not an unexplained-load signal.
        if let activity, let activityDeviation = activity.deviation, activityDeviation > 0.5 {
            return nil
        }

        return HealthSignal(
            kind: .unusualPhysiologicalLoad,
            date: rhrOrStrain.date,
            severity: Self.severity(forAbsoluteZ: deviation),
            confidence: Self.confidence(for: baseline),
            supportingStates: activity.map { [rhrOrStrain, $0] } ?? [rhrOrStrain],
            explanation: "\(rhrOrStrain.metric.displayName) is elevated without a matching rise in recorded activity — the cause isn't explained by exercise in Health data."
        )
    }

    /// Capability 3 — recovery debt: recent strain has been elevated and
    /// resting heart rate hasn't come back down yet.
    func detectRecoveryDebt(recentStrainStates: [MetricState], currentRHRState: MetricState) -> HealthSignal? {
        guard let rhrBaseline = currentRHRState.baseline, rhrBaseline.isReliable,
            let rhrDeviation = currentRHRState.deviation, rhrDeviation >= normalRangeThreshold else { return nil }

        let elevatedStrainDays = recentStrainStates.filter { ($0.deviation ?? 0) >= normalRangeThreshold }.count
        guard elevatedStrainDays >= minimumElevatedStrainDaysForRecoveryDebt else { return nil }

        return HealthSignal(
            kind: .recoveryDebt,
            date: currentRHRState.date,
            severity: Self.severity(forAbsoluteZ: max(rhrDeviation, deviationThreshold)),
            confidence: Self.confidence(for: rhrBaseline),
            supportingStates: [currentRHRState] + recentStrainStates,
            explanation: "Resting heart rate is still \(Self.formatted(rhrDeviation))\u{03C3} above baseline after \(elevatedStrainDays) day(s) of elevated strain — recovery may be lagging behind recent load."
        )
    }

    // MARK: - Shared helpers

    private static func severity(forAbsoluteZ z: Double) -> SignalSeverity {
        switch z {
        case ..<1.5: .info
        case ..<2.0: .mild
        case ..<3.0: .moderate
        default: .significant
        }
    }

    /// Saturates as sample count grows past the reliable minimum. Simple
    /// and monotonic rather than a fitted curve — a placeholder worth
    /// revisiting once there's real data to calibrate against.
    private static func confidence(for baseline: MetricBaseline) -> Double {
        min(1.0, Double(baseline.sampleCount) / Double(MetricBaseline.minimumReliableSampleCount * 2))
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

//
//  HealthInsight.swift
//  HealthIntelligence
//
//  ============================================================
//  The Health Intelligence pipeline
//  ============================================================
//
//      HealthKit
//          |
//      HealthKitService        raw HealthKit data -> HealthKit-independent models
//          |
//      HealthAnalyzer           per-day Strain / Sleep / Activity facts
//          |
//      HealthHistoryBuilder     stitches per-day facts into weeks of history
//          |
//      PersonalBaselineEngine   this person's own mean / SD / trend / percentile
//          |
//      HealthSignalDetector     "is X true, right now"
//          |
//      HealthPatternDetector    "what story do several true things tell together"
//          |
//      HealthInsightEngine (this file) -> [HealthInsight]
//
//  Every stage before HealthInsightEngine is either HealthKit-agnostic
//  (PersonalBaselineEngine, HealthSignalDetector, HealthPatternDetector —
//  all pure functions over plain values, all unit-tested with synthetic
//  data) or already-tested per-day analysis (HealthAnalyzer). This file's
//  job is only to run that pipeline and phrase the result in plain
//  language; it introduces no new math of its own.
//
//  This is a deterministic system, end to end. No LLM interprets raw health
//  data anywhere in this pipeline — every number a HealthInsight cites
//  traces back to an arithmetic mean, standard deviation, or least-squares
//  slope over the user's own history, computed in PersonalBaselineEngine.
//
//  ------------------------------------------------------------
//  What's implemented vs. deliberately deferred
//  ------------------------------------------------------------
//
//  Implemented — reliably supportable today with a few weeks of HealthKit
//  history and no new infrastructure:
//
//    1. Meaningful baseline deviation   -> HealthSignalDetector.detectBaselineDeviation
//    2. Sustained trends                -> HealthSignalDetector.detectSustainedTrend
//    3. Recovery debt                   -> HealthSignalDetector.detectRecoveryDebt
//    8. Unusual physiological load       -> HealthSignalDetector.detectUnusualPhysiologicalLoad
//   10. Emerging deterioration           -> HealthPatternDetector.detectEmergingDeterioration
//   11. Bounce-back                     -> HealthSignalDetector.detectBounceBack
//
//  Deliberately deferred — each needs either months of longitudinal
//  history, a persisted episode store, or correlation-discovery
//  infrastructure this app doesn't have yet. Forcing them now, on a few
//  weeks of data, would produce confident-sounding but statistically
//  meaningless claims — exactly what this system is designed not to do:
//
//    4. Strain tolerance — needs many historical high-strain "episodes"
//       and their outcomes to characterize a personal dose-response curve.
//       One or two hard days isn't a curve.
//    5. Recovery time — needs episode segmentation (start/end of each
//       high-strain period) tracked over months. That needs a persisted
//       history store, not just a rolling HealthKit query recomputed on
//       launch (see HealthHistoryBuilder's cost notes).
//    6/7. Sleep <-> Strain relationships — genuine correlation analysis
//       needs many nights of paired data to avoid spurious correlations;
//       a handful of weeks produces noise dressed up as a finding.
//    9. Positive adaptation — needs workout-similarity matching (same rough
//       workload) plus a longitudinal comparison of physiological cost for
//       matched workloads over time.
//   12. Personal discoveries — general correlation mining across all
//       metric pairs. The least constrained capability and the easiest to
//       produce false positives from with limited history — the last one
//       to build, once 1-11 are validated against real data.
//
//  Extension point: HealthPatternKind and HealthSignalKind both have
//  comments marking where these would slot in without changing the shape
//  of anything upstream.
//
//  ------------------------------------------------------------
//  Minimum data requirements & confidence limitations
//  ------------------------------------------------------------
//
//  - A metric's baseline is only used for signals once
//    `MetricBaseline.isReliable` is true (>= 14 days of history). Below
//    that, MetricState still reports a raw deviation/percentile if it's
//    mathematically computable (>= 3 days), but HealthSignalDetector will
//    not turn it into a HealthSignal. `InsightsViewModel` surfaces this to
//    the user directly as "still building your baseline," rather than
//    hiding the wait silently.
//  - Every HealthSignal and HealthPattern carries a `confidence` (0...1)
//    driven by how much data backs it (baseline sample count, trend
//    consistency) — never by how dramatic the underlying number looks.
//  - Strain history is only computed for a short recent window (see
//    HealthHistoryBuilder.strainWindowDays) because it requires intraday
//    heart-rate samples, which are too expensive to pull for months at a
//    time. Recovery-debt and unusual-load reasoning about strain is
//    therefore inherently short-horizon, not a 45-day baseline like RHR,
//    sleep, or activity.
//

import Foundation

struct HealthInsight: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let narrative: String
    let severity: SignalSeverity
    let confidence: Double
    let date: Date
    let supportingPatterns: [HealthPattern]
}

struct HealthInsightEngine {
    var baselineEngine = PersonalBaselineEngine()
    var signalDetector = HealthSignalDetector()
    var patternDetector = HealthPatternDetector()

    init() {}

    /// Runs the full pipeline over already-built daily history and returns
    /// the day's insights, most severe first.
    func generateInsights(
        from snapshots: [DailyHealthSnapshot],
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> [HealthInsight] {
        guard !snapshots.isEmpty else { return [] }

        let seriesByMetric = Self.series(from: snapshots)

        var statesByMetric: [IntelligenceMetric: [MetricState]] = [:]
        for metric in IntelligenceMetric.allCases {
            guard let series = seriesByMetric[metric] else { continue }
            statesByMetric[metric] = baselineEngine.metricStates(
                metric: metric,
                series: series,
                referenceDate: referenceDate,
                calendar: calendar
            )
        }

        var signals: [HealthSignal] = []
        var trendSignals: [HealthSignal] = []

        for states in statesByMetric.values {
            guard let latest = states.last else { continue }

            if let signal = signalDetector.detectBaselineDeviation(latest) {
                signals.append(signal)
            }
            if let signal = signalDetector.detectSustainedTrend(latest) {
                signals.append(signal)
                trendSignals.append(signal)
            }
            if states.count >= 2 {
                let previous = states[states.count - 2]
                if let signal = signalDetector.detectBounceBack(previous: previous, current: latest) {
                    signals.append(signal)
                }
            }
        }

        var patterns: [HealthPattern] = []

        if let deterioration = patternDetector.detectEmergingDeterioration(trendSignals: trendSignals, date: referenceDate) {
            patterns.append(deterioration)
        }

        if let currentRHR = statesByMetric[.restingHeartRate]?.last {
            let recentStrain = Array((statesByMetric[.strainScore] ?? []).suffix(3))
            if let debtSignal = signalDetector.detectRecoveryDebt(recentStrainStates: recentStrain, currentRHRState: currentRHR) {
                signals.append(debtSignal)
                if let pattern = patternDetector.detectRecoveryDebt(from: debtSignal, date: referenceDate) {
                    patterns.append(pattern)
                }
            }

            let activityState = statesByMetric[.activeEnergy]?.last
            if let loadSignal = signalDetector.detectUnusualPhysiologicalLoad(rhrOrStrain: currentRHR, activity: activityState) {
                signals.append(loadSignal)
                if let pattern = patternDetector.detectUnusualPhysiologicalLoad(from: loadSignal, date: referenceDate) {
                    patterns.append(pattern)
                }
            }
        }

        if let bouncePattern = patternDetector.detectBounceBack(from: signals, date: referenceDate) {
            patterns.append(bouncePattern)
        }

        return Self.insights(from: patterns, standaloneSignals: signals)
            .sorted { $0.severity > $1.severity }
    }

    // MARK: - Series construction

    private static func series(from snapshots: [DailyHealthSnapshot]) -> [IntelligenceMetric: [Date: Double]] {
        var result: [IntelligenceMetric: [Date: Double]] = [:]
        for snapshot in snapshots {
            if let rhr = snapshot.restingHeartRate {
                result[.restingHeartRate, default: [:]][snapshot.date] = rhr
            }
            if let sleep = snapshot.sleepDuration {
                result[.sleepDuration, default: [:]][snapshot.date] = sleep
            }
            result[.steps, default: [:]][snapshot.date] = snapshot.steps
            result[.activeEnergy, default: [:]][snapshot.date] = snapshot.activeEnergy
            if let strain = snapshot.strainScore {
                result[.strainScore, default: [:]][snapshot.date] = strain
            }
        }
        return result
    }

    // MARK: - Insight phrasing

    private static func insights(from patterns: [HealthPattern], standaloneSignals: [HealthSignal]) -> [HealthInsight] {
        var results: [HealthInsight] = patterns.map { pattern in
            HealthInsight(
                title: title(for: pattern.kind),
                narrative: pattern.explanation,
                severity: pattern.severity,
                confidence: pattern.confidence,
                date: pattern.date,
                supportingPatterns: [pattern]
            )
        }

        // Baseline-deviation signals not already folded into a pattern
        // above still deserve their own insight.
        let patternedSignalIDs = Set(patterns.flatMap { $0.signals.map(\.id) })
        for signal in standaloneSignals where signal.kind == .baselineDeviation && !patternedSignalIDs.contains(signal.id) {
            results.append(HealthInsight(
                title: "\(signal.supportingStates.first?.metric.displayName ?? "A metric") looks different than usual",
                narrative: signal.explanation,
                severity: signal.severity,
                confidence: signal.confidence,
                date: signal.date,
                supportingPatterns: []
            ))
        }

        return results
    }

    private static func title(for kind: HealthPatternKind) -> String {
        switch kind {
        case .emergingDeterioration: "Multiple metrics trending unfavorably"
        case .recoveryDebt: "Recovery may be lagging behind recent strain"
        case .unusualPhysiologicalLoad: "Unexplained physiological load"
        case .bounceBack: "Back to your normal"
        }
    }
}

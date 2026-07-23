//
//  HealthPattern.swift
//  HealthIntelligence
//
//  Groups related HealthSignals into a single coherent pattern. Where a
//  HealthSignal answers "is X true," a HealthPattern answers "what bigger
//  story do several true things, together, tell." See HealthInsight.swift
//  for the full pipeline picture and for which capabilities are
//  deliberately not implemented yet.
//
//  Pipeline stage: Signal Detection -> [this] -> Insight Engine
//
//  Pure and HealthKit-independent — every detector here takes already-built
//  HealthSignals, so it's directly unit-testable (see
//  HealthPatternDetectorTests).
//

import Foundation

enum HealthPatternKind: Sendable {
    case emergingDeterioration
    case recoveryDebt
    case unusualPhysiologicalLoad
    case bounceBack

    // Deliberately not implemented yet — see HealthInsight.swift's file
    // header for why each needs more history or infrastructure than the
    // app currently has: strainTolerance, recoveryTime,
    // sleepRecoveryRelationship, strainSleepRelationship,
    // positiveAdaptation, personalDiscovery.
}

struct HealthPattern: Identifiable, Sendable {
    let id = UUID()
    let kind: HealthPatternKind
    let date: Date
    let severity: SignalSeverity
    let confidence: Double
    let signals: [HealthSignal]
    let explanation: String
}

struct HealthPatternDetector {
    /// Minimum simultaneous unfavorable sustained-trend signals before this
    /// counts as "several things moving together" rather than one metric
    /// having a rough week.
    var minimumSignalsForEmergingDeterioration: Int = 2

    init() {}

    /// Capability 10 — emerging deterioration: several metrics trending
    /// unfavorably at once. Stronger, and more actionable, than any one
    /// metric's individual trend signal.
    func detectEmergingDeterioration(trendSignals: [HealthSignal], date: Date) -> HealthPattern? {
        let unfavorable = trendSignals.filter { $0.kind == .sustainedTrend && $0.severity >= .moderate }
        guard unfavorable.count >= minimumSignalsForEmergingDeterioration else { return nil }

        let metricNames = unfavorable.compactMap { $0.supportingStates.first?.metric.displayName }
        let confidence = unfavorable.map(\.confidence).reduce(0, +) / Double(unfavorable.count)

        return HealthPattern(
            kind: .emergingDeterioration,
            date: date,
            severity: unfavorable.map(\.severity).max() ?? .moderate,
            confidence: confidence,
            signals: unfavorable,
            explanation: "Several metrics are moving unfavorably at the same time: \(metricNames.joined(separator: ", "))."
        )
    }

    /// Recovery debt inherently spans two metrics (recent strain history +
    /// current RHR), so it's surfaced as a pattern even though it's built
    /// from a single signal — wrapping it here keeps that call visible in
    /// one place rather than special-cased in the insight engine.
    func detectRecoveryDebt(from signal: HealthSignal?, date: Date) -> HealthPattern? {
        guard let signal, signal.kind == .recoveryDebt else { return nil }
        return HealthPattern(
            kind: .recoveryDebt,
            date: date,
            severity: signal.severity,
            confidence: signal.confidence,
            signals: [signal],
            explanation: signal.explanation
        )
    }

    func detectUnusualPhysiologicalLoad(from signal: HealthSignal?, date: Date) -> HealthPattern? {
        guard let signal, signal.kind == .unusualPhysiologicalLoad else { return nil }
        return HealthPattern(
            kind: .unusualPhysiologicalLoad,
            date: date,
            severity: signal.severity,
            confidence: signal.confidence,
            signals: [signal],
            explanation: signal.explanation
        )
    }

    func detectBounceBack(from signals: [HealthSignal], date: Date) -> HealthPattern? {
        let bounceSignals = signals.filter { $0.kind == .bounceBack }
        guard !bounceSignals.isEmpty else { return nil }

        let metricNames = bounceSignals.compactMap { $0.supportingStates.last?.metric.displayName }
        let confidence = bounceSignals.map(\.confidence).reduce(0, +) / Double(bounceSignals.count)

        return HealthPattern(
            kind: .bounceBack,
            date: date,
            severity: .info,
            confidence: confidence,
            signals: bounceSignals,
            explanation: "\(metricNames.joined(separator: ", ")) returned toward your personal baseline."
        )
    }
}

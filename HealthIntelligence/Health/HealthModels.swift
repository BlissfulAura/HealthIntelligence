//
//  HealthModels.swift
//  HealthIntelligence
//
//  Application-level representation of health data. The rest of the app
//  works with these types; HealthKit specifics stay inside HealthKitService.
//

import Foundation

// MARK: - Metric type

/// The set of numeric health metrics the app currently understands.
///
/// Heart rate, resting heart rate, steps, and energy values all share the
/// same shape (a scalar value over a time interval), so they share
/// `HealthMetricSample` rather than each getting a bespoke type.
enum HealthMetricType: String, CaseIterable, Sendable {
    case heartRate
    case restingHeartRate
    case steps
    case activeEnergyBurned
    case basalEnergyBurned

    var displayName: String {
        switch self {
        case .heartRate: "Heart Rate"
        case .restingHeartRate: "Resting Heart Rate"
        case .steps: "Steps"
        case .activeEnergyBurned: "Active Energy"
        case .basalEnergyBurned: "Resting Energy"
        }
    }

    /// Short unit label for display purposes only. Actual unit conversion
    /// happens in HealthKitService when reading from HealthKit.
    var unitSymbol: String {
        switch self {
        case .heartRate, .restingHeartRate: "bpm"
        case .steps: "steps"
        case .activeEnergyBurned, .basalEnergyBurned: "kcal"
        }
    }
}

// MARK: - Provenance

/// Which device/app a sample came from. Useful because a single metric
/// (e.g. heart rate) may be written by both a Garmin watch and iPhone.
struct HealthSource: Sendable, Hashable {
    let name: String
    let bundleIdentifier: String
}

// MARK: - Numeric samples

/// A single scalar health measurement over a time interval.
struct HealthMetricSample: Identifiable, Sendable {
    let id = UUID()
    let type: HealthMetricType
    let value: Double
    let startDate: Date
    let endDate: Date
    let source: HealthSource
}

// MARK: - Sleep

/// Sleep stage as reported by HealthKit's category samples. `.unspecified`
/// covers sources (potentially including Garmin's HealthKit writer) that
/// report only "asleep" without stage-level detail.
enum SleepStage: String, CaseIterable, Sendable {
    case inBed
    case awake
    case core
    case deep
    case rem
    case unspecified
}

/// One contiguous stretch of a single sleep stage.
struct SleepStageSegment: Identifiable, Sendable {
    let id = UUID()
    let stage: SleepStage
    let startDate: Date
    let endDate: Date
    let source: HealthSource

    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }
}

/// A group of sleep-stage segments considered part of the same night's sleep.
///
/// Segments are grouped by HealthKitService based on time proximity rather
/// than assumed to come from a single source, since multiple devices
/// (Garmin + iPhone) may all write overlapping sleep data for the same night.
struct SleepSession: Sendable {
    let segments: [SleepStageSegment]

    var startDate: Date? { segments.map(\.startDate).min() }
    var endDate: Date? { segments.map(\.endDate).max() }

    /// Wall-clock span from first to last segment. Not the same as time
    /// asleep, since it may include `.awake` or `.inBed` segments.
    var timeSpan: TimeInterval? {
        guard let startDate, let endDate else { return nil }
        return endDate.timeIntervalSince(startDate)
    }

    /// Sum of all segments that represent actual sleep (excludes `.awake`
    /// and `.inBed`).
    var totalTimeAsleep: TimeInterval {
        segments
            .filter { $0.stage != .awake && $0.stage != .inBed }
            .reduce(0) { $0 + $1.duration }
    }

    func totalDuration(for stage: SleepStage) -> TimeInterval {
        segments
            .filter { $0.stage == stage }
            .reduce(0) { $0 + $1.duration }
    }
}

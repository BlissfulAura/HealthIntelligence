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
///
/// HRV, respiration rate, and blood oxygen have real HealthKit quantity
/// types but weren't fetched from HealthKit until the Garmin data import
/// feature needed to write them (see Import/GarminExportImporter.swift).
/// Stress and Body Battery are Garmin-proprietary concepts with no HealthKit
/// equivalent at all — samples of those types never come from
/// HealthKitService, only from an import source, and are persisted
/// separately (see GarminSupplementalMetricsStore).
enum HealthMetricType: String, CaseIterable, Sendable, Codable {
    case heartRate
    case restingHeartRate
    case steps
    case activeEnergyBurned
    case basalEnergyBurned
    case heartRateVariability
    case respirationRate
    case bloodOxygen
    case stress
    case bodyBattery

    var displayName: String {
        switch self {
        case .heartRate: "Heart Rate"
        case .restingHeartRate: "Resting Heart Rate"
        case .steps: "Steps"
        case .activeEnergyBurned: "Active Energy"
        case .basalEnergyBurned: "Resting Energy"
        case .heartRateVariability: "Heart Rate Variability"
        case .respirationRate: "Respiration Rate"
        case .bloodOxygen: "Blood Oxygen"
        case .stress: "Stress"
        case .bodyBattery: "Body Battery"
        }
    }

    /// Short unit label for display purposes only. Actual unit conversion
    /// happens in HealthKitService when reading from HealthKit.
    var unitSymbol: String {
        switch self {
        case .heartRate, .restingHeartRate: "bpm"
        case .steps: "steps"
        case .activeEnergyBurned, .basalEnergyBurned: "kcal"
        case .heartRateVariability: "ms"
        case .respirationRate: "brpm"
        case .bloodOxygen: "%"
        case .stress, .bodyBattery: "" // both are unitless 0...100 Garmin scores
        }
    }
}

// MARK: - Characteristic data

/// From HealthKit's characteristic (profile) data. Used only to pick the
/// Banister TRIMP exponent constant in the Strain calculation — never to
/// gate or alter what data is shown to the user.
enum BiologicalSex: Sendable {
    case male
    case female
    /// Covers HealthKit's `.notSet` and `.other`, and the case where
    /// characteristic data isn't authorized/available at all.
    case unspecified
}

// MARK: - Provenance

/// Which device/app a sample came from. Useful because a single metric
/// (e.g. heart rate) may be written by both a Garmin watch and iPhone.
struct HealthSource: Sendable, Hashable, Codable {
    let name: String
    let bundleIdentifier: String
    /// The true original provenance for a sample this app *wrote* into
    /// HealthKit on an import's behalf (e.g. "Garmin Connect Export").
    /// HealthKit always attributes a written sample's `name`/
    /// `bundleIdentifier` to the writing app — it has no concept of "this
    /// app wrote it, but it really came from there" — so this is carried
    /// as custom sample metadata instead (see
    /// `originalSourceMetadataKey`) and is `nil` for samples that were
    /// never imported.
    var originalSourceDescription: String?

    /// The HKMetadata key used to stash `originalSourceDescription` on
    /// samples this app writes to HealthKit. Shared between the write path
    /// (HealthKitService) and the read path (the `HKSample` conversion
    /// extension in the same file) so they never drift apart.
    static let originalSourceMetadataKey = "com.healthintelligence.import.originalSource"
}

// MARK: - Numeric samples

/// A single scalar health measurement over a time interval.
struct HealthMetricSample: Identifiable, Sendable, Codable {
    let id: UUID
    let type: HealthMetricType
    let value: Double
    let startDate: Date
    let endDate: Date
    let source: HealthSource

    init(id: UUID = UUID(), type: HealthMetricType, value: Double, startDate: Date, endDate: Date, source: HealthSource) {
        self.id = id
        self.type = type
        self.value = value
        self.startDate = startDate
        self.endDate = endDate
        self.source = source
    }
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

// MARK: - Workouts

/// A single logged workout. Used to identify which heart-rate samples
/// reflect exercise rather than unexplained resting-state strain.
struct Workout: Identifiable, Sendable {
    let id = UUID()
    let activityName: String
    let startDate: Date
    let endDate: Date
    /// Active energy burned during the workout, when the source recorded it.
    /// Not every source (including some Garmin activity types) populates this.
    let totalActiveEnergyBurned: Double?
    let source: HealthSource

    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }

    func contains(_ date: Date) -> Bool {
        date >= startDate && date <= endDate
    }
}

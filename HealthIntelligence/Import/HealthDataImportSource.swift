//
//  HealthDataImportSource.swift
//  HealthIntelligence
//
//  The extension point for bringing external health data into the app.
//  GarminExportImporter is the first (and currently only) implementation;
//  a future source (a different watch brand's export, a plain CSV, etc.)
//  just needs its own type conforming to this protocol. The destination
//  services it would write through — HealthKitService's save methods,
//  GarminSupplementalMetricsStore — aren't Garmin-specific, so a new
//  source can reuse them directly rather than building a parallel system.
//

import Foundation

/// One category of health data an import can contribute, independent of
/// which source it came from. Used purely for the user-facing summary —
/// not a pipeline stage of its own.
enum ImportedDataCategory: String, CaseIterable, Sendable {
    case heartRate
    case restingHeartRate
    case heartRateVariability
    case sleep
    case stress
    case bodyBattery
    case respirationRate
    case bloodOxygen
    case steps
    case activeEnergy
    case workouts

    var displayName: String {
        switch self {
        case .heartRate: "Heart Rate"
        case .restingHeartRate: "Resting Heart Rate"
        case .heartRateVariability: "Heart Rate Variability"
        case .sleep: "Sleep"
        case .stress: "Stress"
        case .bodyBattery: "Body Battery"
        case .respirationRate: "Respiration Rate"
        case .bloodOxygen: "Blood Oxygen"
        case .steps: "Steps"
        case .activeEnergy: "Active Energy"
        case .workouts: "Workouts"
        }
    }
}

/// What an import found and did with it — deliberately plain counts, not a
/// health interpretation of any kind.
struct ImportSummary: Sendable {
    let sourceName: String
    /// Records successfully parsed and written (to HealthKit, or to
    /// GarminSupplementalMetricsStore for the couple of types HealthKit has
    /// no equivalent for), per category.
    let importedCounts: [ImportedDataCategory: Int]
    /// Records that were recognized and valid, but skipped because data
    /// already existed for that day/timestamp — see GarminExportImporter's
    /// dedup policy for exactly what "already existed" means per category.
    let skippedDuplicateCounts: [ImportedDataCategory: Int]
    /// Files found in the archive that weren't recognized as one of the
    /// supported categories above (including binary activity files, which
    /// aren't parsed in detail — see GarminExportImporter). Counted, never
    /// silently discarded.
    let unrecognizedFileCount: Int
    let dateRange: ClosedRange<Date>?

    var totalImported: Int { importedCounts.values.reduce(0, +) }
    var totalSkippedDuplicates: Int { skippedDuplicateCounts.values.reduce(0, +) }
}

/// Something that can read an external export and bring its health data
/// into the app. `url` is a single file the user picked (e.g. a ZIP); how
/// it's structured internally is entirely up to the conforming type.
protocol HealthDataImportSource {
    var sourceDisplayName: String { get }
    func `import`(from url: URL) async throws -> ImportSummary
}

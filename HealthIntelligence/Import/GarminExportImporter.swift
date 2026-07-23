//
//  GarminExportImporter.swift
//  HealthIntelligence
//
//  Implements HealthDataImportSource for a Garmin Connect "Export Your
//  Data" account export ZIP. The pipeline:
//
//      ZIP file -> MinimalZip (list/read entries)
//               -> JSONSerialization (parse each .json entry)
//               -> GarminRecordClassifier (shape-sniff each record)
//               -> app's existing Health models (HealthMetricSample,
//                  SleepSession, Workout)
//               -> dedup against what's already there
//               -> HealthKitService writes (HealthKit-native types) or
//                  GarminSupplementalMetricsStore (Stress, Body Battery)
//               -> ImportSummary
//
//  Automatically inspects every entry in the archive rather than asking
//  the user to pick individual files — anything that isn't recognized is
//  counted as unrecognized, never silently dropped and never treated as a
//  failure.
//
//  Duplicate handling is intentionally simple and conservative: for
//  continuous metrics (heart rate, HRV, respiration, blood oxygen, steps,
//  active energy, resting heart rate), a calendar day is skipped entirely
//  if HealthKit already has *any* sample of that type on that day — this
//  favors not creating duplicates over perfectly reconciling partial-day
//  gaps. Sleep is skipped per night on the same basis. Workouts are
//  skipped individually when their time range overlaps an existing
//  workout. Stress and Body Battery have no HealthKit presence to check
//  against, so GarminSupplementalMetricsStore dedups by exact timestamp
//  instead.
//

import Foundation

struct GarminExportImporter: HealthDataImportSource {
    let sourceDisplayName = "Garmin Connect Export"

    private let healthKitService: HealthKitService
    private let supplementalStore: GarminSupplementalMetricsStore
    private let classifier: GarminRecordClassifier

    init(
        healthKitService: HealthKitService,
        supplementalStore: GarminSupplementalMetricsStore = GarminSupplementalMetricsStore(),
        classifier: GarminRecordClassifier = GarminRecordClassifier()
    ) {
        self.healthKitService = healthKitService
        self.supplementalStore = supplementalStore
        self.classifier = classifier
    }

    func `import`(from url: URL) async throws -> ImportSummary {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

        let archive = try MinimalZip(fileURL: url)
        let jsonEntries = archive.entries.filter { $0.path.lowercased().hasSuffix(".json") }
        let otherEntryCount = archive.entries.count - jsonEntries.count

        let source = HealthSource(
            name: "Garmin Connect",
            bundleIdentifier: "com.garmin.connect.import",
            originalSourceDescription: sourceDisplayName
        )

        var collected = CollectedRecords()
        var unrecognizedFileCount = 0

        for entry in jsonEntries {
            guard let data = try? archive.contents(of: entry),
                let json = try? JSONSerialization.jsonObject(with: data) else {
                unrecognizedFileCount += 1
                continue
            }

            let records = Self.records(from: json)
            guard !records.isEmpty else {
                unrecognizedFileCount += 1
                continue
            }

            for record in records {
                collected.absorb(record, using: classifier, source: source, unrecognizedFileCount: &unrecognizedFileCount)
            }
        }

        // Ensure both read and write authorization before touching
        // HealthKit — a no-op if already granted.
        try await healthKitService.requestAuthorization()

        var importedCounts: [ImportedDataCategory: Int] = [:]
        var skippedCounts: [ImportedDataCategory: Int] = [:]

        try await importContinuousMetric(collected.restingHeartRate, category: .restingHeartRate, into: &importedCounts, skipped: &skippedCounts)
        try await importContinuousMetric(collected.heartRate, category: .heartRate, into: &importedCounts, skipped: &skippedCounts)
        try await importContinuousMetric(collected.steps, category: .steps, into: &importedCounts, skipped: &skippedCounts)
        try await importContinuousMetric(collected.activeEnergy, category: .activeEnergy, into: &importedCounts, skipped: &skippedCounts)
        try await importContinuousMetric(collected.heartRateVariability, category: .heartRateVariability, into: &importedCounts, skipped: &skippedCounts)
        try await importContinuousMetric(collected.respiration, category: .respirationRate, into: &importedCounts, skipped: &skippedCounts)
        try await importContinuousMetric(collected.bloodOxygen, category: .bloodOxygen, into: &importedCounts, skipped: &skippedCounts)

        try await importSleep(collected.sleepSessions, into: &importedCounts, skipped: &skippedCounts)
        try await importWorkouts(collected.activities, into: &importedCounts, skipped: &skippedCounts)

        let stressInserted = (try? supplementalStore.upsert(collected.stress)) ?? 0
        importedCounts[.stress] = stressInserted
        skippedCounts[.stress] = collected.stress.count - stressInserted

        let bodyBatteryInserted = (try? supplementalStore.upsert(collected.bodyBattery)) ?? 0
        importedCounts[.bodyBattery] = bodyBatteryInserted
        skippedCounts[.bodyBattery] = collected.bodyBattery.count - bodyBatteryInserted

        return ImportSummary(
            sourceName: sourceDisplayName,
            importedCounts: importedCounts,
            skippedDuplicateCounts: skippedCounts,
            unrecognizedFileCount: unrecognizedFileCount + otherEntryCount,
            dateRange: collected.dateRange()
        )
    }

    // MARK: - Continuous metrics (day-level dedup against HealthKit)

    private func importContinuousMetric(
        _ samples: [HealthMetricSample],
        category: ImportedDataCategory,
        into importedCounts: inout [ImportedDataCategory: Int],
        skipped skippedCounts: inout [ImportedDataCategory: Int]
    ) async throws {
        guard let first = samples.first else { return }
        let calendar = Calendar.current
        guard let start = samples.map(\.startDate).min(), let end = samples.map(\.startDate).max() else { return }
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end

        let existing = (try? await healthKitService.existingSamples(ofType: first.type, from: calendar.startOfDay(for: start), to: rangeEnd)) ?? []
        let existingDays = Set(existing.map { calendar.startOfDay(for: $0.startDate) })

        let toImport = samples.filter { !existingDays.contains(calendar.startOfDay(for: $0.startDate)) }
        if !toImport.isEmpty {
            try await healthKitService.saveQuantitySamples(toImport)
        }
        importedCounts[category, default: 0] += toImport.count
        skippedCounts[category, default: 0] += samples.count - toImport.count
    }

    // MARK: - Sleep (per-night dedup)

    private func importSleep(
        _ sessions: [SleepSession],
        into importedCounts: inout [ImportedDataCategory: Int],
        skipped skippedCounts: inout [ImportedDataCategory: Int]
    ) async throws {
        guard !sessions.isEmpty else { return }
        let calendar = Calendar.current
        guard let start = sessions.compactMap(\.startDate).min(), let end = sessions.compactMap(\.endDate).max() else { return }

        let existingSessions = (try? await healthKitService.sleepSessions(from: calendar.startOfDay(for: start), to: end)) ?? []
        let existingNights = Set(existingSessions.compactMap { $0.startDate.map { calendar.startOfDay(for: $0) } })

        var importedSegmentCount = 0
        var skippedSegmentCount = 0

        for session in sessions {
            guard let night = session.startDate.map({ calendar.startOfDay(for: $0) }) else { continue }
            if existingNights.contains(night) {
                skippedSegmentCount += session.segments.count
                continue
            }
            try await healthKitService.saveSleepSegments(session.segments)
            importedSegmentCount += session.segments.count
        }

        importedCounts[.sleep, default: 0] += importedSegmentCount
        skippedCounts[.sleep, default: 0] += skippedSegmentCount
    }

    // MARK: - Workouts (per-workout overlap dedup)

    private func importWorkouts(
        _ activities: [GarminActivityExtraction],
        into importedCounts: inout [ImportedDataCategory: Int],
        skipped skippedCounts: inout [ImportedDataCategory: Int]
    ) async throws {
        guard !activities.isEmpty else { return }
        let calendar = Calendar.current
        guard let start = activities.map(\.workout.startDate).min(), let end = activities.map(\.workout.endDate).max() else { return }

        let existingWorkouts = (try? await healthKitService.workouts(from: calendar.startOfDay(for: start), to: end)) ?? []

        var imported = 0
        var skipped = 0
        for activity in activities {
            let overlaps = existingWorkouts.contains { existing in
                existing.contains(activity.workout.startDate) || activity.workout.contains(existing.startDate)
            }
            if overlaps {
                skipped += 1
                continue
            }
            try await healthKitService.saveWorkout(activity.workout, activityTypeHint: activity.rawActivityTypeName)
            imported += 1
        }

        importedCounts[.workouts, default: 0] += imported
        skippedCounts[.workouts, default: 0] += skipped
    }

    // MARK: - JSON record extraction

    /// Garmin's wellness files are typically a JSON array of per-day
    /// records; some (like activity summaries) wrap the array in a single
    /// object key. This generically finds "the array of records"
    /// regardless of which shape a given file uses, rather than hardcoding
    /// wrapper key names that may not match every export.
    private static func records(from json: Any) -> [[String: Any]] {
        if let array = json as? [[String: Any]] { return array }
        if let array = json as? [Any] { return array.compactMap { $0 as? [String: Any] } }
        if let object = json as? [String: Any] {
            for value in object.values {
                if let array = value as? [[String: Any]] { return array }
                if let array = value as? [Any] {
                    let dicts = array.compactMap { $0 as? [String: Any] }
                    if !dicts.isEmpty { return dicts }
                }
            }
            return [object]
        }
        return []
    }

    /// Accumulates extracted samples across every record in the archive
    /// before any HealthKit interaction, so the (potentially large) parse
    /// pass and the (definitely I/O-bound) write pass stay clearly separate.
    private struct CollectedRecords {
        var restingHeartRate: [HealthMetricSample] = []
        var heartRate: [HealthMetricSample] = []
        var steps: [HealthMetricSample] = []
        var activeEnergy: [HealthMetricSample] = []
        var heartRateVariability: [HealthMetricSample] = []
        var stress: [HealthMetricSample] = []
        var bodyBattery: [HealthMetricSample] = []
        var respiration: [HealthMetricSample] = []
        var bloodOxygen: [HealthMetricSample] = []
        var sleepSessions: [SleepSession] = []
        var activities: [GarminActivityExtraction] = []

        mutating func absorb(
            _ record: [String: Any],
            using classifier: GarminRecordClassifier,
            source: HealthSource,
            unrecognizedFileCount: inout Int
        ) {
            switch classifier.kind(of: record) {
            case .dailySummary:
                let extraction = classifier.extractDailySummary(from: record, source: source)
                if let rhr = extraction.restingHeartRate { restingHeartRate.append(rhr) }
                if let steps = extraction.steps { self.steps.append(steps) }
                if let energy = extraction.activeEnergy { activeEnergy.append(energy) }
                heartRate.append(contentsOf: extraction.heartRateSamples)
            case .sleep:
                if let session = classifier.extractSleep(from: record, source: source) {
                    sleepSessions.append(session)
                } else {
                    unrecognizedFileCount += 1
                }
            case .heartRateVariability:
                heartRateVariability.append(contentsOf: classifier.extractHeartRateVariability(from: record, source: source))
            case .stressAndBodyBattery:
                let extraction = classifier.extractStressAndBodyBattery(from: record, source: source)
                stress.append(contentsOf: extraction.stress)
                bodyBattery.append(contentsOf: extraction.bodyBattery)
            case .respiration:
                respiration.append(contentsOf: classifier.extractRespiration(from: record, source: source))
            case .bloodOxygen:
                bloodOxygen.append(contentsOf: classifier.extractBloodOxygen(from: record, source: source))
            case .activity:
                if let activity = classifier.extractActivity(from: record, source: source) {
                    activities.append(activity)
                } else {
                    unrecognizedFileCount += 1
                }
            case .unrecognized:
                unrecognizedFileCount += 1
            }
        }

        func dateRange() -> ClosedRange<Date>? {
            let dates = [restingHeartRate, heartRate, steps, activeEnergy, heartRateVariability, stress, bodyBattery, respiration, bloodOxygen]
                .flatMap { $0 }.map(\.startDate)
                + sleepSessions.compactMap(\.startDate)
                + activities.map(\.workout.startDate)
            guard let earliest = dates.min(), let latest = dates.max() else { return nil }
            return earliest...latest
        }
    }
}

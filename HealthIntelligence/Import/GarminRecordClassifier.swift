//
//  GarminRecordClassifier.swift
//  HealthIntelligence
//
//  Pure JSON-shape detection and extraction for records found inside a
//  Garmin Connect "Export Your Data" account export.
//
//  Garmin does not publish an official schema for this export. The field
//  names here were reverse-engineered from two overlapping public sources:
//  community reports of real exports (e.g. daily wellness files named like
//  "<start>_<end>_<userId>_sleepData.json", containing arrays of per-day
//  records with camelCase fields such as "sleepStartTimestampGMT"), and
//  Garmin's own published Health API documentation, which uses PascalCase
//  for what appears to be the same underlying data model (e.g.
//  "CalendarDate", "TimeOffsetStressLevelValues"). Since the exact casing
//  in any given real export can't be verified without a live sample, every
//  lookup here is case-insensitive by construction (see
//  `value(forCaseInsensitiveKey:)`) rather than hardcoded to one
//  convention.
//
//  A record whose shape doesn't match anything recognized here is reported
//  as `.unrecognized` rather than guessed at — see HealthDataImportSource
//  and GarminExportImporter, which count and surface these to the user
//  instead of silently dropping them. Confidence in the exact field names
//  varies by category: Sleep, HRV, Stress/Body Battery, and the combined
//  Daily Summary are corroborated by multiple independent sources;
//  standalone Respiration/Blood-Oxygen files and Activity summaries are
//  best-effort. Extend the alias lists below as real exports are tested
//  against this importer.
//

import Foundation

enum GarminRecordKind {
    case dailySummary
    case sleep
    case heartRateVariability
    case stressAndBodyBattery
    case respiration
    case bloodOxygen
    case activity
    case unrecognized
}

struct GarminDailySummaryExtraction {
    var restingHeartRate: HealthMetricSample?
    var steps: HealthMetricSample?
    var activeEnergy: HealthMetricSample?
    var heartRateSamples: [HealthMetricSample] = []
}

struct GarminStressExtraction {
    var stress: [HealthMetricSample] = []
    var bodyBattery: [HealthMetricSample] = []
}

/// A parsed activity, plus the source's own free-text activity type name
/// (needed separately from `Workout.activityName` because HealthKitService
/// maps *that* raw name to an `HKWorkoutActivityType` when writing it).
struct GarminActivityExtraction {
    let workout: Workout
    let rawActivityTypeName: String
}

struct GarminRecordClassifier {
    init() {}

    func kind(of record: [String: Any]) -> GarminRecordKind {
        if record.hasAnyKey("sleepLevelsMap", "deepSleepDurationInSeconds", "deepSleepSeconds", "sleepStartTimestampGmt") {
            return .sleep
        }
        if record.hasAnyKey("hrvValues", "lastNightAvg") {
            return .heartRateVariability
        }
        if record.hasAnyKey("timeOffsetStressLevelValues", "timeOffsetBodyBatteryValues") {
            return .stressAndBodyBattery
        }
        if record.hasAnyKey("respirationValuesMap", "avgWakingRespirationValue", "lowestRespirationValue") {
            return .respiration
        }
        if record.hasAnyKey("spo2ValuesArray", "averageSpo2", "lowestSpo2", "spo2HourlyAverages") {
            return .bloodOxygen
        }
        if record.hasAnyKey("activityType", "activityName"),
            record.hasAnyKey("startTimeGmt", "startTimeInSeconds", "beginTimestamp") {
            return .activity
        }
        if record.hasAnyKey("restingHeartRate", "restingHeartRateInBeatsPerMinute"),
            record.hasAnyKey("timeOffsetHeartRateSamples", "heartRateValues", "totalSteps", "steps") {
            return .dailySummary
        }
        return .unrecognized
    }

    // MARK: - Daily summary (resting HR, steps, active energy, intraday HR)

    func extractDailySummary(from record: [String: Any], source: HealthSource) -> GarminDailySummaryExtraction {
        var result = GarminDailySummaryExtraction()

        let anchor = instant(record, "calendarDate", "startTimeInSeconds")
        let dayEnd = anchor.map { $0.addingTimeInterval(number(record, "durationInSeconds") ?? 86400) }

        if let rhr = number(record, "restingHeartRate", "restingHeartRateInBeatsPerMinute"), let anchor {
            result.restingHeartRate = HealthMetricSample(type: .restingHeartRate, value: rhr, startDate: anchor, endDate: anchor, source: source)
        }
        if let stepsValue = number(record, "totalSteps", "steps"), let anchor, let dayEnd {
            result.steps = HealthMetricSample(type: .steps, value: stepsValue, startDate: anchor, endDate: dayEnd, source: source)
        }
        if let energy = number(record, "activeKilocalories", "activeCalories"), let anchor, let dayEnd {
            result.activeEnergy = HealthMetricSample(type: .activeEnergyBurned, value: energy, startDate: anchor, endDate: dayEnd, source: source)
        }

        if let baseTime = instant(record, "startTimeInSeconds"),
            let hrMap = object(record, "timeOffsetHeartRateSamples", "heartRateValues") {
            result.heartRateSamples = Self.timeSeries(from: hrMap, baseTime: baseTime, metric: .heartRate, source: source) { $0 >= 0 }
        }

        return result
    }

    // MARK: - Sleep

    func extractSleep(from record: [String: Any], source: HealthSource) -> SleepSession? {
        guard let sessionStart = instant(record, "startTimeInSeconds", "sleepStartTimestampGmt", "sleepStartTimestampLocal") else {
            return nil
        }

        var segments: [SleepStageSegment] = []

        if let levels = object(record, "sleepLevelsMap") {
            for (levelName, value) in levels {
                guard let stage = SleepStage(garminLevelName: levelName), let ranges = value as? [Any] else { continue }
                for case let range as [String: Any] in ranges {
                    guard let start = instant(range, "startTimeInSeconds", "startGmt"),
                        let end = instant(range, "endTimeInSeconds", "endGmt") else { continue }
                    segments.append(SleepStageSegment(stage: stage, startDate: start, endDate: end, source: source))
                }
            }
        }

        // Fallback for a record with only aggregate durations, no per-stage
        // timeline: represent the whole monitored period as one
        // unspecified-stage segment rather than reporting nothing.
        if segments.isEmpty, let duration = number(record, "durationInSeconds"), duration > 0 {
            segments.append(SleepStageSegment(
                stage: .unspecified,
                startDate: sessionStart,
                endDate: sessionStart.addingTimeInterval(duration),
                source: source
            ))
        }

        guard !segments.isEmpty else { return nil }
        return SleepSession(segments: segments)
    }

    // MARK: - Heart rate variability

    func extractHeartRateVariability(from record: [String: Any], source: HealthSource) -> [HealthMetricSample] {
        guard let baseTime = instant(record, "startTimeInSeconds"), let values = object(record, "hrvValues") else { return [] }
        return Self.timeSeries(from: values, baseTime: baseTime, metric: .heartRateVariability, source: source) { $0 > 0 }
    }

    // MARK: - Stress + Body Battery

    func extractStressAndBodyBattery(from record: [String: Any], source: HealthSource) -> GarminStressExtraction {
        var result = GarminStressExtraction()
        guard let baseTime = instant(record, "startTimeInSeconds") else { return result }

        if let values = object(record, "timeOffsetStressLevelValues") {
            // Negative values are sentinels (off-wrist, motion, insufficient
            // data, post-exercise, unidentified) per Garmin's documented
            // stress-detail format, not real stress readings.
            result.stress = Self.timeSeries(from: values, baseTime: baseTime, metric: .stress, source: source) { $0 >= 0 }
        }
        if let values = object(record, "timeOffsetBodyBatteryValues") {
            result.bodyBattery = Self.timeSeries(from: values, baseTime: baseTime, metric: .bodyBattery, source: source) { _ in true }
        }
        return result
    }

    // MARK: - Respiration / Blood oxygen

    func extractRespiration(from record: [String: Any], source: HealthSource) -> [HealthMetricSample] {
        guard let baseTime = instant(record, "startTimeInSeconds"),
            let values = object(record, "respirationValuesMap", "timeOffsetSleepRespiration") else { return [] }
        return Self.timeSeries(from: values, baseTime: baseTime, metric: .respirationRate, source: source) { $0 > 0 }
    }

    func extractBloodOxygen(from record: [String: Any], source: HealthSource) -> [HealthMetricSample] {
        guard let baseTime = instant(record, "startTimeInSeconds"),
            let values = object(record, "spo2ValuesMap", "timeOffsetSleepSpo2") else { return [] }
        return Self.timeSeries(from: values, baseTime: baseTime, metric: .bloodOxygen, source: source) { $0 > 0 }
    }

    // MARK: - Activity

    func extractActivity(from record: [String: Any], source: HealthSource) -> GarminActivityExtraction? {
        guard let start = instant(record, "startTimeInSeconds", "startTimeGmt", "beginTimestamp") else { return nil }
        guard let duration = number(record, "durationInSeconds", "duration"), duration > 0 else { return nil }

        let rawType = string(record, "activityType") ?? "workout"
        let calories = number(record, "activeKilocalories", "calories")

        let workout = Workout(
            activityName: Self.displayName(forGarminActivityType: rawType),
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            totalActiveEnergyBurned: calories,
            source: source
        )
        return GarminActivityExtraction(workout: workout, rawActivityTypeName: rawType)
    }

    private static func displayName(forGarminActivityType raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: - Shared helpers

    /// Converts a Garmin "offset seconds since a base time" -> value map
    /// into timestamped samples, filtering out values a category considers
    /// invalid (e.g. negative stress sentinels).
    private static func timeSeries(
        from map: [String: Any],
        baseTime: Date,
        metric: HealthMetricType,
        source: HealthSource,
        isValid: (Double) -> Bool
    ) -> [HealthMetricSample] {
        map.compactMap { offsetKey, rawValue in
            guard let offset = Double(offsetKey), let value = Self.doubleValue(rawValue), isValid(value) else { return nil }
            let date = baseTime.addingTimeInterval(offset)
            return HealthMetricSample(type: metric, value: value, startDate: date, endDate: date, source: source)
        }
    }

    private static func doubleValue(_ raw: Any) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let text = raw as? String { return Double(text) }
        return nil
    }

    private func number(_ record: [String: Any], _ keys: String...) -> Double? {
        Self.number(record, keys)
    }

    private static func number(_ record: [String: Any], _ keys: [String]) -> Double? {
        for key in keys {
            if let raw = record.value(forCaseInsensitiveKey: key), let value = doubleValue(raw) { return value }
        }
        return nil
    }

    private func string(_ record: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = record.value(forCaseInsensitiveKey: key) as? String { return value }
        }
        return nil
    }

    private func object(_ record: [String: Any], _ keys: String...) -> [String: Any]? {
        for key in keys {
            if let value = record.value(forCaseInsensitiveKey: key) as? [String: Any] { return value }
        }
        return nil
    }

    /// Finds a timestamp under any of `keys`, trying each in order.
    /// Handles both schema conventions seen across Garmin's export and its
    /// Health API docs: Unix epoch seconds (numeric or numeric string), or
    /// a "yyyy-MM-dd[THH:mm:ss[.S]]" style string (used for both plain
    /// calendar dates and full timestamps).
    private func instant(_ record: [String: Any], _ keys: String...) -> Date? {
        for key in keys {
            guard let raw = record.value(forCaseInsensitiveKey: key) else { continue }
            if let number = raw as? NSNumber {
                return Date(timeIntervalSince1970: number.doubleValue)
            }
            if let text = raw as? String {
                if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
                for formatter in Self.dateFormatters {
                    if let date = formatter.date(from: text) { return date }
                }
            }
        }
        return nil
    }

    private static let dateFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ss.S", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"].map { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter
        }
    }()
}

// MARK: - Case-insensitive JSON key lookup

private extension Dictionary where Key == String {
    /// A full case-insensitive scan rather than trying a couple of casing
    /// permutations — cheap given a record has a few dozen keys at most,
    /// and robust to whatever exact convention a real export turns out to
    /// use (see this file's header).
    func value(forCaseInsensitiveKey key: String) -> Any? {
        if let value = self[key] { return value }
        let lowered = key.lowercased()
        for (candidateKey, value) in self where candidateKey.lowercased() == lowered {
            return value
        }
        return nil
    }

    func hasAnyKey(_ keys: String...) -> Bool {
        keys.contains { value(forCaseInsensitiveKey: $0) != nil }
    }
}

// MARK: - Garmin-specific naming

private extension SleepStage {
    init?(garminLevelName: String) {
        switch garminLevelName.lowercased() {
        case "deep": self = .deep
        case "light": self = .core // Garmin's "light" is the closest match to HealthKit's "core" sleep concept.
        case "rem": self = .rem
        case "awake": self = .awake
        default: return nil
        }
    }
}

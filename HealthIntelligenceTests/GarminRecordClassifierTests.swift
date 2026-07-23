//
//  GarminRecordClassifierTests.swift
//  HealthIntelligenceTests
//
//  Coverage for shape detection and extraction against synthetic JSON
//  records in both camelCase and PascalCase (see GarminRecordClassifier's
//  header for why both need to work), plus the "don't guess" behavior for
//  genuinely unrecognized shapes.
//

import XCTest
@testable import HealthIntelligence

final class GarminRecordClassifierTests: XCTestCase {
    private let classifier = GarminRecordClassifier()
    private let source = HealthSource(name: "Garmin Connect", bundleIdentifier: "com.garmin.connect.import", originalSourceDescription: "Garmin Connect Export")

    // MARK: - Classification

    func test_classifiesSleepRecord() {
        let record: [String: Any] = [
            "sleepStartTimestampGMT": "2024-01-15T06:00:00.0",
            "sleepLevelsMap": [
                "deep": [["startTimeInSeconds": 1_705_298_400, "endTimeInSeconds": 1_705_300_200]],
            ],
        ]
        XCTAssertEqual(classifier.kind(of: record), .sleep)
    }

    func test_classifiesDailySummaryRecord() {
        let record: [String: Any] = [
            "restingHeartRate": 52,
            "totalSteps": 8000,
            "timeOffsetHeartRateSamples": ["0": 60, "300": 65],
        ]
        XCTAssertEqual(classifier.kind(of: record), .dailySummary)
    }

    func test_classifiesDailySummaryRecord_pascalCase() {
        // Same shape, PascalCase keys — the Garmin Health API convention.
        let record: [String: Any] = [
            "RestingHeartRateInBeatsPerMinute": 52,
            "Steps": 8000,
        ]
        XCTAssertEqual(classifier.kind(of: record), .dailySummary)
    }

    func test_classifiesHRVRecord() {
        let record: [String: Any] = ["hrvValues": ["0": 45, "300": 48], "startTimeInSeconds": 1_705_298_400]
        XCTAssertEqual(classifier.kind(of: record), .heartRateVariability)
    }

    func test_classifiesStressRecord() {
        let record: [String: Any] = ["timeOffsetStressLevelValues": ["0": 25], "startTimeInSeconds": 1_705_298_400]
        XCTAssertEqual(classifier.kind(of: record), .stressAndBodyBattery)
    }

    func test_classifiesActivityRecord() {
        let record: [String: Any] = ["activityType": "running", "startTimeGmt": 1_705_298_400, "durationInSeconds": 1800]
        XCTAssertEqual(classifier.kind(of: record), .activity)
    }

    func test_unrecognizedRecordIsNotForcedIntoAnyCategory() {
        let record: [String: Any] = ["someTotallyUnknownField": 42, "anotherOne": "value"]
        XCTAssertEqual(classifier.kind(of: record), .unrecognized)
    }

    // MARK: - Extraction: daily summary

    func test_extractDailySummary_pullsRestingHeartRateStepsAndIntradayHeartRate() {
        let record: [String: Any] = [
            "calendarDate": "2024-01-15",
            "startTimeInSeconds": 1_705_298_400,
            "durationInSeconds": 86400,
            "restingHeartRate": 52,
            "totalSteps": 8123,
            "activeKilocalories": 450,
            "timeOffsetHeartRateSamples": ["0": 60, "300": 72],
        ]

        let extraction = classifier.extractDailySummary(from: record, source: source)

        XCTAssertEqual(extraction.restingHeartRate?.value, 52)
        XCTAssertEqual(extraction.steps?.value, 8123)
        XCTAssertEqual(extraction.activeEnergy?.value, 450)
        XCTAssertEqual(extraction.heartRateSamples.count, 2)
        XCTAssertTrue(extraction.heartRateSamples.contains { $0.value == 60 })
        XCTAssertTrue(extraction.heartRateSamples.contains { $0.value == 72 })
        XCTAssertEqual(extraction.restingHeartRate?.source.originalSourceDescription, "Garmin Connect Export")
    }

    // MARK: - Extraction: sleep

    func test_extractSleep_buildsSegmentsFromLevelsMap() {
        let record: [String: Any] = [
            "startTimeInSeconds": 1_705_298_400,
            "sleepLevelsMap": [
                "deep": [["startTimeInSeconds": 1_705_298_400, "endTimeInSeconds": 1_705_300_200]],
                "rem": [["startTimeInSeconds": 1_705_300_200, "endTimeInSeconds": 1_705_302_000]],
            ],
        ]

        let session = classifier.extractSleep(from: record, source: source)

        XCTAssertNotNil(session)
        XCTAssertEqual(session?.segments.count, 2)
        XCTAssertTrue(session?.segments.contains { $0.stage == .deep } ?? false)
        XCTAssertTrue(session?.segments.contains { $0.stage == .rem } ?? false)
    }

    func test_extractSleep_fallsBackToUnspecifiedWhenNoLevelsMap() {
        let record: [String: Any] = ["startTimeInSeconds": 1_705_298_400, "durationInSeconds": 7200]

        let session = classifier.extractSleep(from: record, source: source)

        XCTAssertEqual(session?.segments.count, 1)
        XCTAssertEqual(session?.segments.first?.stage, .unspecified)
        XCTAssertEqual(session?.segments.first?.duration ?? -1, 7200, accuracy: 0.01)
    }

    func test_extractSleep_nilWhenNoTimestampAtAll() {
        let record: [String: Any] = ["deepSleepDurationInSeconds": 3600]
        XCTAssertNil(classifier.extractSleep(from: record, source: source))
    }

    // MARK: - Extraction: HRV

    func test_extractHeartRateVariability_convertsOffsetMapToSamples() {
        let record: [String: Any] = ["startTimeInSeconds": 1_705_298_400, "hrvValues": ["0": 45, "60": 50]]

        let samples = classifier.extractHeartRateVariability(from: record, source: source)

        XCTAssertEqual(samples.count, 2)
        XCTAssertTrue(samples.allSatisfy { $0.type == .heartRateVariability })
    }

    // MARK: - Extraction: stress + body battery

    func test_extractStressAndBodyBattery_filtersNegativeStressSentinels() {
        let record: [String: Any] = [
            "startTimeInSeconds": 1_705_298_400,
            // -1/-2/-3/-4/-5 are documented Garmin sentinels (off-wrist,
            // motion, insufficient data, post-exercise, unidentified), not
            // real stress readings, and should be dropped.
            "timeOffsetStressLevelValues": ["0": 25, "60": -1, "120": -3],
            "timeOffsetBodyBatteryValues": ["0": 80, "60": 78],
        ]

        let extraction = classifier.extractStressAndBodyBattery(from: record, source: source)

        XCTAssertEqual(extraction.stress.count, 1)
        XCTAssertEqual(extraction.stress.first?.value, 25)
        XCTAssertEqual(extraction.bodyBattery.count, 2)
    }

    // MARK: - Extraction: activity

    func test_extractActivity_producesWorkoutAndPreservesRawType() {
        let record: [String: Any] = [
            "activityType": "road_biking",
            "startTimeGmt": 1_705_298_400,
            "durationInSeconds": 3600,
            "activeKilocalories": 600,
        ]

        let extraction = classifier.extractActivity(from: record, source: source)

        XCTAssertNotNil(extraction)
        XCTAssertEqual(extraction?.rawActivityTypeName, "road_biking")
        XCTAssertEqual(extraction?.workout.activityName, "Road Biking")
        XCTAssertEqual(extraction?.workout.duration ?? -1, 3600, accuracy: 0.01)
        XCTAssertEqual(extraction?.workout.totalActiveEnergyBurned, 600)
    }

    func test_extractActivity_nilWithoutDuration() {
        let record: [String: Any] = ["activityType": "running", "startTimeGmt": 1_705_298_400]
        XCTAssertNil(classifier.extractActivity(from: record, source: source))
    }
}

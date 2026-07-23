//
//  GarminSupplementalMetricsStoreTests.swift
//  HealthIntelligenceTests
//
//  Coverage for the local store's upsert-by-(type, timestamp) dedup —
//  the policy that lets the same or an overlapping Garmin export be
//  re-imported without duplicating Stress/Body Battery history.
//

import XCTest
@testable import HealthIntelligence

final class GarminSupplementalMetricsStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: GarminSupplementalMetricsStore!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = GarminSupplementalMetricsStore(directory: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func sample(value: Double, date: Date, type: HealthMetricType = .stress) -> HealthMetricSample {
        HealthMetricSample(
            type: type,
            value: value,
            startDate: date,
            endDate: date,
            source: HealthSource(name: "Garmin Connect", bundleIdentifier: "com.garmin.connect.import")
        )
    }

    func test_upsert_returnsInsertedCountForNewSamples() throws {
        let date1 = Date(timeIntervalSince1970: 1_705_298_400)
        let date2 = Date(timeIntervalSince1970: 1_705_298_700)

        let inserted = try store.upsert([sample(value: 25, date: date1), sample(value: 30, date: date2)])

        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(try store.samples(type: .stress, from: date1, to: date2.addingTimeInterval(1)).count, 2)
    }

    func test_upsert_doesNotDuplicateSameTimestampOnReimport() throws {
        let date = Date(timeIntervalSince1970: 1_705_298_400)
        _ = try store.upsert([sample(value: 25, date: date)])

        // Re-importing the exact same (type, timestamp) should upsert, not duplicate.
        let secondInsertCount = try store.upsert([sample(value: 25, date: date)])

        XCTAssertEqual(secondInsertCount, 0)
        XCTAssertEqual(try store.samples(type: .stress, from: date, to: date.addingTimeInterval(1)).count, 1)
    }

    func test_upsert_updatesValueForSameTimestamp() throws {
        let date = Date(timeIntervalSince1970: 1_705_298_400)
        _ = try store.upsert([sample(value: 25, date: date)])
        _ = try store.upsert([sample(value: 40, date: date)])

        let samples = try store.samples(type: .stress, from: date, to: date.addingTimeInterval(1))
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.value, 40)
    }

    func test_samples_filtersToRequestedTypeAndRange() throws {
        let inRange = Date(timeIntervalSince1970: 1_705_298_400)
        let outOfRange = Date(timeIntervalSince1970: 1_705_400_000)
        _ = try store.upsert([
            sample(value: 25, date: inRange, type: .stress),
            sample(value: 80, date: inRange, type: .bodyBattery),
            sample(value: 30, date: outOfRange, type: .stress),
        ])

        let result = try store.samples(type: .stress, from: inRange.addingTimeInterval(-1), to: inRange.addingTimeInterval(1))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.value, 25)
    }
}

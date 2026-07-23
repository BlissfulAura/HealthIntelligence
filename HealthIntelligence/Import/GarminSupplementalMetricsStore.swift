//
//  GarminSupplementalMetricsStore.swift
//  HealthIntelligence
//
//  Local persistence for metrics HealthKit has no equivalent for at all.
//  Garmin's Stress and Body Battery scores are proprietary concepts, not
//  HealthKit quantity types — everything else an import finds goes into
//  HealthKit itself (see HealthKitService's save methods), which already
//  knows how to store and provenance-tag samples. This store only exists
//  for the couple of types with nowhere else to live.
//
//  Backed by a single JSON file in the app's Application Support
//  directory rather than SwiftData/CoreData: the data is a flat,
//  append-mostly array of samples — small enough (one person's Stress and
//  Body Battery history) that a full persistence framework would be
//  overhead without benefit. Everything in this file stays on-device.
//

import Foundation

struct GarminSupplementalMetricsStore {
    private let fileURL: URL

    /// `directory` is exposed for testing (an isolated temp directory);
    /// production code should just use the default (the app's real
    /// Application Support directory).
    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let directory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("GarminSupplementalMetrics.json")
    }

    /// Merges new samples in, keyed by (type, exact timestamp), so
    /// re-importing the same export — or an overlapping one — upserts
    /// rather than duplicates. Returns how many were genuinely new.
    @discardableResult
    func upsert(_ newSamples: [HealthMetricSample]) throws -> Int {
        guard !newSamples.isEmpty else { return 0 }

        var byKey = Dictionary(uniqueKeysWithValues: (try load()).map { (Self.key(for: $0), $0) })

        var insertedCount = 0
        for sample in newSamples {
            let key = Self.key(for: sample)
            if byKey[key] == nil { insertedCount += 1 }
            byKey[key] = sample
        }

        try save(Array(byKey.values).sorted { $0.startDate < $1.startDate })
        return insertedCount
    }

    func samples(type: HealthMetricType, from start: Date, to end: Date) throws -> [HealthMetricSample] {
        try load().filter { $0.type == type && $0.startDate >= start && $0.startDate < end }
    }

    private func load() throws -> [HealthMetricSample] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([HealthMetricSample].self, from: data)
    }

    private func save(_ samples: [HealthMetricSample]) throws {
        let data = try JSONEncoder().encode(samples)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func key(for sample: HealthMetricSample) -> String {
        "\(sample.type.rawValue)|\(sample.startDate.timeIntervalSince1970)"
    }
}

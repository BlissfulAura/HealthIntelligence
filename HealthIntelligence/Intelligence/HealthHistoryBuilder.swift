//
//  HealthHistoryBuilder.swift
//  HealthIntelligence
//
//  Builds the day-by-day history the intelligence pipeline needs, by
//  bucketing HealthKitService's range queries into calendar days and
//  reusing HealthAnalyzer for the (more expensive) daily Strain score.
//
//  This is the one file in the intelligence pipeline that talks to
//  HealthKitService directly — everything downstream (PersonalBaselineEngine,
//  HealthSignalDetector, HealthPatternDetector, HealthInsightEngine) is pure
//  and HealthKit-independent, which is what makes those unit-testable
//  without a device or Health access. This file is not unit-tested for the
//  same reason HealthKitService itself isn't: it has no logic of its own to
//  verify beyond "does it call HealthKit correctly," which only a real
//  device can answer.
//
//  Cost note: RHR, steps, active energy, and sleep are cheap to fetch over
//  months (roughly one RHR sample and one sleep session per day), so
//  `historyWindowDays` can comfortably cover the baseline window. Strain
//  needs intraday heart-rate samples, which are not cheap over months, so
//  it's deliberately bounded to a much shorter `strainWindowDays`. A future
//  milestone should persist daily snapshots locally rather than
//  recomputing this from raw HealthKit on every launch.
//

import Foundation

struct DailyHealthSnapshot: Sendable {
    let date: Date
    let restingHeartRate: Double?
    let sleepDuration: TimeInterval?
    let steps: Double
    let activeEnergy: Double
    /// Only populated for the most recent `strainWindowDays` — see this
    /// file's header for why.
    let strainScore: Double?
}

struct HealthHistoryBuilder {
    private let healthKitService: HealthKitService
    private let analyzer: HealthAnalyzer

    /// Days of RHR/sleep/steps/energy history to fetch.
    var historyWindowDays: Int = 60
    /// Days to compute a full TRIMP strain score for (see file header).
    var strainWindowDays: Int = 10

    init(healthKitService: HealthKitService, analyzer: HealthAnalyzer = HealthAnalyzer()) {
        self.healthKitService = healthKitService
        self.analyzer = analyzer
    }

    func buildHistory(endingAt referenceDate: Date = Date(), calendar: Calendar = .current) async throws -> [DailyHealthSnapshot] {
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate)) ?? referenceDate
        guard let historyStart = calendar.date(byAdding: .day, value: -historyWindowDays, to: endExclusive),
            let strainWindowStart = calendar.date(byAdding: .day, value: -strainWindowDays, to: endExclusive),
            // Strain's own RHR baseline needs 30 days before the strain
            // window starts, so RHR is fetched further back than everything
            // else — reused per-day below instead of re-queried per day.
            let rhrFetchStart = calendar.date(byAdding: .day, value: -30, to: historyStart) else {
            return []
        }

        async let rhrSamples = healthKitService.restingHeartRateSamples(from: rhrFetchStart, to: endExclusive)
        async let stepSamples = healthKitService.stepSamples(from: historyStart, to: endExclusive)
        async let activeEnergySamples = healthKitService.activeEnergySamples(from: historyStart, to: endExclusive)
        async let sleepSessions = healthKitService.sleepSessions(from: historyStart, to: endExclusive)
        async let strainWindowHeartRate = healthKitService.heartRateSamples(from: strainWindowStart, to: endExclusive)
        async let strainWindowWorkouts = healthKitService.workouts(from: strainWindowStart, to: endExclusive)

        let (rhr, steps, activeEnergy, sleep, heartRate, workouts) = try await (
            rhrSamples, stepSamples, activeEnergySamples, sleepSessions, strainWindowHeartRate, strainWindowWorkouts
        )

        let dailyRHR = Self.dailyValues(from: rhr, calendar: calendar, aggregation: .average)
        let dailySteps = Self.dailyValues(from: steps, calendar: calendar, aggregation: .sum)
        let dailyActiveEnergy = Self.dailyValues(from: activeEnergy, calendar: calendar, aggregation: .sum)
        let dailySleep = Self.dailySleepDuration(from: sleep, calendar: calendar)
        let dailyStrain = strainByDay(
            heartRate: heartRate,
            workouts: workouts,
            rhrSamples: rhr,
            from: strainWindowStart,
            to: referenceDate,
            calendar: calendar
        )

        let allDays = Set(dailyRHR.keys)
            .union(dailySteps.keys)
            .union(dailyActiveEnergy.keys)
            .union(dailySleep.keys)
            .union(dailyStrain.keys)

        return allDays.sorted().map { day in
            DailyHealthSnapshot(
                date: day,
                restingHeartRate: dailyRHR[day],
                sleepDuration: dailySleep[day],
                steps: dailySteps[day] ?? 0,
                activeEnergy: dailyActiveEnergy[day] ?? 0,
                strainScore: dailyStrain[day]
            )
        }
    }

    // MARK: - Daily strain

    private func strainByDay(
        heartRate: [HealthMetricSample],
        workouts: [Workout],
        rhrSamples: [HealthMetricSample],
        from start: Date,
        to referenceDate: Date,
        calendar: Calendar
    ) -> [Date: Double] {
        let age = healthKitService.age()
        let sex = healthKitService.biologicalSex()

        var result: [Date: Double] = [:]
        var day = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: referenceDate)

        while day <= lastDay {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                let baselineStart = calendar.date(byAdding: .day, value: -30, to: day) else { break }

            let dayHeartRate = heartRate.filter { $0.startDate >= day && $0.startDate < nextDay }
            if !dayHeartRate.isEmpty {
                let dayWorkouts = workouts.filter { $0.startDate >= day && $0.startDate < nextDay }
                let baselineRHR = rhrSamples.filter { $0.startDate >= baselineStart && $0.startDate < day }
                let todayRHR = rhrSamples.filter { $0.startDate >= day && $0.startDate < nextDay }.last

                let strain = analyzer.analyzeStrain(
                    todayRestingHeartRate: todayRHR,
                    baselineRestingHeartRateSamples: baselineRHR,
                    todayHeartRateSamples: dayHeartRate,
                    todayWorkouts: dayWorkouts,
                    age: age,
                    biologicalSex: sex,
                    measuredMaximumHeartRate: nil
                )
                result[day] = strain.strain.strainScore
            }

            day = nextDay
        }

        return result
    }

    // MARK: - Daily bucketing

    private enum Aggregation {
        case sum
        case average
    }

    private static func dailyValues(from samples: [HealthMetricSample], calendar: Calendar, aggregation: Aggregation) -> [Date: Double] {
        let grouped = Dictionary(grouping: samples) { calendar.startOfDay(for: $0.startDate) }
        return grouped.mapValues { daySamples in
            switch aggregation {
            case .sum: daySamples.reduce(0) { $0 + $1.value }
            case .average: daySamples.reduce(0) { $0 + $1.value } / Double(daySamples.count)
            }
        }
    }

    private static func dailySleepDuration(from sessions: [SleepSession], calendar: Calendar) -> [Date: TimeInterval] {
        var result: [Date: TimeInterval] = [:]
        for session in sessions {
            guard let start = session.startDate else { continue }
            let day = calendar.startOfDay(for: start)
            result[day, default: 0] += session.totalTimeAsleep
        }
        return result
    }
}

//
//  DashboardViewModel.swift
//  HealthIntelligence
//
//  Coordinates HealthKitService -> HealthAnalyzer -> dashboard state.
//  Owns no HealthKit query logic and no analysis math itself.
//

import Foundation
import Observation

@Observable
final class DashboardViewModel {
    struct DashboardData {
        let strain: StrainAnalysis
        let sleep: SleepAnalysis
        let activity: ActivityAnalysis
    }

    enum State {
        case idle
        case loading
        case ready(DashboardData)
        /// Every query came back empty. HealthKit's privacy model means we
        /// can't distinguish "user denied read access" from "no data has
        /// been recorded yet" — see HealthKitService.requestAuthorization.
        case noData
        case error(String)
    }

    private(set) var state: State = .idle

    private let healthKitService: HealthKitService
    private let analyzer: HealthAnalyzer

    init(healthKitService: HealthKitService, analyzer: HealthAnalyzer = HealthAnalyzer()) {
        self.healthKitService = healthKitService
        self.analyzer = analyzer
    }

    func load() async {
        state = .loading

        guard healthKitService.isHealthDataAvailable else {
            state = .error(HealthKitServiceError.notAvailable.localizedDescription)
            return
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        guard let baselineStart = calendar.date(byAdding: .day, value: -30, to: startOfToday),
            let sleepWindowStart = calendar.date(byAdding: .hour, value: -32, to: now) else {
            state = .error("Unable to compute date ranges.")
            return
        }

        do {
            try await healthKitService.requestAuthorization()

            async let restingHRToday = healthKitService.restingHeartRateSamples(from: startOfToday, to: now)
            async let restingHRBaseline = healthKitService.restingHeartRateSamples(from: baselineStart, to: startOfToday)
            async let stepsToday = healthKitService.stepSamples(from: startOfToday, to: now)
            async let stepsBaseline = healthKitService.stepSamples(from: baselineStart, to: startOfToday)
            async let activeEnergyToday = healthKitService.activeEnergySamples(from: startOfToday, to: now)
            async let sleepSessions = healthKitService.sleepSessions(from: sleepWindowStart, to: now)

            let (rhrToday, rhrBaseline, todaySteps, baselineSteps, todayActiveEnergy, sessions) = try await (
                restingHRToday, restingHRBaseline, stepsToday, stepsBaseline, activeEnergyToday, sleepSessions
            )

            if rhrToday.isEmpty && todaySteps.isEmpty && sessions.isEmpty {
                state = .noData
                return
            }

            let strain = analyzer.analyzeStrain(
                todayRestingHeartRate: rhrToday.last,
                baselineRestingHeartRateSamples: rhrBaseline
            )
            let sleep = analyzer.analyzeSleep(mostRecentSession: sessions.last)
            let activity = analyzer.analyzeActivity(
                todaySteps: todaySteps,
                todayActiveEnergy: todayActiveEnergy,
                baselineDailySteps: Self.dailyTotals(from: baselineSteps, calendar: calendar)
            )

            state = .ready(DashboardData(strain: strain, sleep: sleep, activity: activity))
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private static func dailyTotals(from samples: [HealthMetricSample], calendar: Calendar) -> [Double] {
        let grouped = Dictionary(grouping: samples) { calendar.startOfDay(for: $0.startDate) }
        return grouped.values.map { $0.reduce(0) { $0 + $1.value } }
    }
}

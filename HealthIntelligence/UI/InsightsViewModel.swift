//
//  InsightsViewModel.swift
//  HealthIntelligence
//
//  Loads and exposes the longitudinal Health Insight pipeline's output.
//  Kept separate from DashboardViewModel because building history (weeks
//  of HealthKit data, plus several days of TRIMP recomputation — see
//  HealthHistoryBuilder) is meaningfully more expensive than "today's
//  snapshot," and shouldn't block the main dashboard from appearing.
//

import Foundation
import Observation

@Observable
final class InsightsViewModel {
    enum State {
        case idle
        case loading
        case ready([HealthInsight])
        /// Not enough history yet for any baseline to be reliable (see
        /// MetricBaseline.minimumReliableSampleCount). Expected for a
        /// newly-installed app or a new HealthKit source — not an error.
        case buildingBaseline
        case error(String)
    }

    private(set) var state: State = .idle
    /// The most recent day's full snapshot (every metric the history
    /// pipeline fetched, not just what's used for insights) — exposed so
    /// the Key Metrics strip can show Garmin's richer data (HRV, VO2 Max,
    /// Body Battery, ...) without DashboardViewModel re-fetching the same
    /// HealthKit history a second time.
    private(set) var latestSnapshot: DailyHealthSnapshot?

    private let historyBuilder: HealthHistoryBuilder
    private let insightEngine: HealthInsightEngine

    init(historyBuilder: HealthHistoryBuilder, insightEngine: HealthInsightEngine = HealthInsightEngine()) {
        self.historyBuilder = historyBuilder
        self.insightEngine = insightEngine
    }

    func load() async {
        state = .loading
        do {
            let snapshots = try await historyBuilder.buildHistory()
            latestSnapshot = snapshots.last
            guard snapshots.count >= MetricBaseline.minimumReliableSampleCount else {
                state = .buildingBaseline
                return
            }
            let insights = insightEngine.generateInsights(from: snapshots, referenceDate: Date())
            state = .ready(insights)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}

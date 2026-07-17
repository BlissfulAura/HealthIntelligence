//
//  HealthIntelligenceApp.swift
//  HealthIntelligence
//
//  Composition root: wires HealthKitService + HealthAnalyzer into the
//  DashboardViewModel and hands it to the root view. No DI framework —
//  explicit construction is enough for this graph.
//

import SwiftUI

@main
struct HealthIntelligenceApp: App {
    private let healthKitService = HealthKitService()
    private let analyzer = HealthAnalyzer()

    var body: some Scene {
        WindowGroup {
            DashboardView(
                viewModel: DashboardViewModel(healthKitService: healthKitService, analyzer: analyzer)
            )
        }
    }
}

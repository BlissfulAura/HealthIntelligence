//
//  DashboardView.swift
//  HealthIntelligence
//
//  Home is intelligence-first: Your Health Today (a simple header) ->
//  Insights (the 2-4 most important, ranked findings from
//  HealthInsightEngine, each with an expandable "why am I seeing this")
//  -> Key Metrics (a compact glance at Strain/Sleep/Activity, demoted from
//  primary content to a secondary strip). No analysis happens in this
//  file — it only renders what HealthInsightEngine and HealthAnalyzer
//  already computed.
//

import SwiftUI

struct DashboardView: View {
    @State private var viewModel: DashboardViewModel
    @State private var insightsViewModel: InsightsViewModel
    @State private var importViewModel: ImportViewModel
    @State private var isImportPresented = false

    /// Keeps the primary feed to a small, deliberately chosen set rather
    /// than dumping every insight the engine could find — "2-4 most
    /// important," not "everything."
    private static let maxFeedInsights = 4

    init(viewModel: DashboardViewModel, insightsViewModel: InsightsViewModel, importViewModel: ImportViewModel) {
        _viewModel = State(initialValue: viewModel)
        _insightsViewModel = State(initialValue: insightsViewModel)
        _importViewModel = State(initialValue: importViewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    insightsSection
                    keyMetricsSection
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isImportPresented = true
                    } label: {
                        Label("Import Data", systemImage: "square.and.arrow.down.on.square")
                    }
                }
            }
            .sheet(isPresented: $isImportPresented, onDismiss: {
                Task {
                    await viewModel.load()
                    await insightsViewModel.load()
                }
            }) {
                ImportView(viewModel: importViewModel)
            }
            .task { await viewModel.load() }
            .task { await insightsViewModel.load() }
            .refreshable {
                await viewModel.load()
                await insightsViewModel.load()
            }
        }
    }

    // MARK: - Your Health Today

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Your Health Today")
                .font(.largeTitle.weight(.bold))
            Text(Date().formatted(date: .complete, time: .omitted))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Insights

    @ViewBuilder
    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insights")
                .font(.headline)
                .padding(.horizontal, 4)

            switch insightsViewModel.state {
            case .idle, .loading:
                PlaceholderCard(symbol: "sparkles") {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking for what matters in your data…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            case .buildingBaseline:
                PlaceholderCard(symbol: "chart.line.uptrend.xyaxis") {
                    Text("Insights need at least \(MetricBaseline.minimumReliableSampleCount) days of Health history — check back soon.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .ready(let insights) where insights.isEmpty:
                PlaceholderCard(symbol: "checkmark.circle") {
                    Text("Nothing stands out from your recent baseline.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .ready(let insights):
                VStack(spacing: 12) {
                    ForEach(Array(insights.prefix(Self.maxFeedInsights))) { insight in
                        InsightFeedCard(insight: insight)
                    }
                }
            case .error(let message):
                PlaceholderCard(symbol: "exclamationmark.triangle") {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Key Metrics

    @ViewBuilder
    private var keyMetricsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Key Metrics")
                .font(.headline)
                .padding(.horizontal, 4)

            switch viewModel.state {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            case .ready(let data):
                KeyMetricsRow(data: data, latestSnapshot: insightsViewModel.latestSnapshot)
            case .noData:
                Text("No Health data found yet. Make sure Health access is granted in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            case .error(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await viewModel.load() } }
                        .font(.caption)
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - Shared containers

private struct PlaceholderCard<Content: View>: View {
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Insight feed card

private struct InsightFeedCard: View {
    let insight: HealthInsight
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(severityColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(insight.title)
                        .font(.headline)
                    Text(insight.narrative)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !insight.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(insight.evidence, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 18)
            }

            if !insight.supportingStates.isEmpty {
                DisclosureGroup("Why am I seeing this?", isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(insight.supportingStates.enumerated()), id: \.offset) { _, state in
                            MetricStateRow(state: state)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.leading, 18)
                }
                .font(.caption.weight(.medium))
                .tint(.secondary)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
    }

    private var severityColor: Color {
        switch insight.severity {
        case .info: .blue
        case .mild: .yellow
        case .moderate: .orange
        case .significant: .red
        }
    }
}

private struct MetricStateRow: View {
    let state: MetricState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(state.metric.displayName)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(state.metric.formattedValue(state.currentValue))
                    .font(.caption.monospacedDigit())
            }

            HStack(spacing: 10) {
                if let baseline = state.baseline {
                    Text("Baseline \(state.metric.formattedValue(baseline.mean))")
                }
                if let deviation = state.deviation {
                    Text("\(deviation >= 0 ? "+" : "")\(String(format: "%.1f", deviation))\u{03C3}")
                }
                if let trend = state.trend, trend.isSustained {
                    Label(
                        trend.direction == .rising ? "Rising" : "Falling",
                        systemImage: trend.direction == .rising ? "arrow.up.right" : "arrow.down.right"
                    )
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Key Metrics row

private struct KeyMetricsRow: View {
    let data: DashboardViewModel.DashboardData
    /// The richer Garmin metrics (HRV, VO2 Max, Body Battery, Stress) — only
    /// shown when actually present, since not every source/day produces
    /// them. `nil` while the longitudinal history is still loading.
    let latestSnapshot: DailyHealthSnapshot?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                KeyMetricTile(
                    symbol: "bolt.heart",
                    tint: .orange,
                    value: data.strain.strain.strainScore.formatted(.number.precision(.fractionLength(0))),
                    label: "Strain",
                    deviation: nil
                )
                KeyMetricTile(
                    symbol: "moon.zzz",
                    tint: .indigo,
                    value: Self.sleepValue(data.sleep),
                    label: "Sleep",
                    deviation: nil
                )
                KeyMetricTile(
                    symbol: "figure.walk",
                    tint: .green,
                    value: "\(Int(data.activity.totalStepsToday))",
                    label: "Steps",
                    deviation: data.activity.percentageDeviationFromBaseline
                )
                if let hrv = latestSnapshot?.heartRateVariability {
                    KeyMetricTile(symbol: "waveform.path.ecg", tint: .pink, value: "\(Int(hrv.rounded()))", label: "HRV", deviation: nil)
                }
                if let vo2Max = latestSnapshot?.vo2Max {
                    KeyMetricTile(symbol: "lungs", tint: .teal, value: String(format: "%.1f", vo2Max), label: "VO2 Max", deviation: nil)
                }
                if let bodyBattery = latestSnapshot?.bodyBattery {
                    KeyMetricTile(symbol: "battery.75", tint: .mint, value: "\(Int(bodyBattery.rounded()))", label: "Body Battery", deviation: nil)
                }
                if let stress = latestSnapshot?.stress {
                    KeyMetricTile(symbol: "brain.head.profile", tint: .purple, value: "\(Int(stress.rounded()))", label: "Stress", deviation: nil)
                }
                if let spo2 = latestSnapshot?.bloodOxygen {
                    KeyMetricTile(symbol: "drop", tint: .blue, value: "\(Int((spo2 * 100).rounded()))%", label: "Blood Oxygen", deviation: nil)
                }
                if let respiration = latestSnapshot?.respirationRate {
                    KeyMetricTile(symbol: "wind", tint: .cyan, value: String(format: "%.0f", respiration), label: "Respiration", deviation: nil)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private static func sleepValue(_ sleep: SleepAnalysis) -> String {
        guard let asleep = sleep.totalTimeAsleep, asleep > 0 else { return "–" }
        let hours = Int(asleep) / 3600
        let minutes = (Int(asleep) % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}

private struct KeyMetricTile: View {
    let symbol: String
    let tint: Color
    let value: String
    let label: String
    let deviation: Double?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let deviation {
                HStack(spacing: 2) {
                    Image(systemName: deviation >= 0 ? "arrow.up.right" : "arrow.down.right")
                    Text("\(Int(abs(deviation)))%")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 92)
        .padding(.vertical, 14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    let healthKitService = HealthKitService()
    DashboardView(
        viewModel: DashboardViewModel(healthKitService: healthKitService),
        insightsViewModel: InsightsViewModel(historyBuilder: HealthHistoryBuilder(healthKitService: healthKitService)),
        importViewModel: ImportViewModel(source: GarminExportImporter(healthKitService: healthKitService))
    )
}

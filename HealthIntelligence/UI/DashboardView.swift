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
        VStack(alignment: .leading, spacing: 16) {
            switch viewModel.state {
            case .idle, .loading:
                Text("Key Metrics")
                    .font(.headline)
                    .padding(.horizontal, 4)
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            case .ready(let data):
                Text("Scores")
                    .font(.headline)
                    .padding(.horizontal, 4)
                ScoresRow(
                    strainScore: data.strain.strain.strainScore,
                    sleepScore: Self.score(for: insightsViewModel.latestStates[.sleepDuration]),
                    sleepSubtitle: Self.sleepValue(data.sleep),
                    activenessScore: Self.activenessScore(states: insightsViewModel.latestStates),
                    activenessSubtitle: "\(Int(data.activity.totalStepsToday)) steps"
                )
                if insightsViewModel.latestSnapshot?.hasAnyVital == true {
                    Text("Vitals")
                        .font(.headline)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                    VitalsRow(latestSnapshot: insightsViewModel.latestSnapshot)
                }
            case .noData:
                Text("Key Metrics")
                    .font(.headline)
                    .padding(.horizontal, 4)
                Text("No Health data found yet. Make sure Health access is granted in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            case .error(let message):
                Text("Key Metrics")
                    .font(.headline)
                    .padding(.horizontal, 4)
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

    /// A 0...100 score is only shown once the metric's personal baseline is
    /// reliable (>= 14 days — the same gate HealthSignalDetector uses)
    /// rather than presenting a confident-looking number off a handful of
    /// days. `MetricState.percentile` is exactly "where today ranks in your
    /// own history" — reused as-is rather than inventing separate scoring
    /// math for Sleep/Activeness the way Strain has its own TRIMP model.
    private static func score(for state: MetricState?) -> Double? {
        guard let state, state.baseline?.isReliable == true else { return nil }
        return state.percentile
    }

    /// Activeness blends Steps' and Active Energy's percentiles — two
    /// independent readings of "how much you moved today vs. your own
    /// history" — averaging whichever of the two are actually available.
    private static func activenessScore(states: [IntelligenceMetric: MetricState]) -> Double? {
        let stepsScore = score(for: states[.steps])
        let energyScore = score(for: states[.activeEnergy])
        switch (stepsScore, energyScore) {
        case let (s?, e?): return (s + e) / 2
        case let (s?, nil): return s
        case let (nil, e?): return e
        case (nil, nil): return nil
        }
    }

    private static func sleepValue(_ sleep: SleepAnalysis) -> String {
        guard let asleep = sleep.totalTimeAsleep, asleep > 0 else { return "No data" }
        let hours = Int(asleep) / 3600
        let minutes = (Int(asleep) % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}

private extension DailyHealthSnapshot {
    var hasAnyVital: Bool {
        heartRateVariability != nil || vo2Max != nil || bodyBattery != nil
            || stress != nil || bloodOxygen != nil || respirationRate != nil
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
    @State private var explanationState: ExplanationState = .idle

    private let narrator = HealthInsightNarrator()

    private enum ExplanationState {
        case idle
        case loading
        case ready(String)
        case error(String)
    }

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

            if !insight.evidence.isEmpty {
                explanationSection
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
    }

    // MARK: - "What might explain this" (on-device LLM, on request only)

    /// Speculative, LLM-generated everyday explanations sit behind a tap
    /// rather than loading automatically — this is the one part of the app
    /// that isn't a plain arithmetic fact about the user's own history, so
    /// it's opt-in and clearly labeled, never presented as a conclusion.
    @ViewBuilder
    private var explanationSection: some View {
        switch explanationState {
        case .idle:
            if case .unavailable(let reason) = narrator.availability {
                Label(reason, systemImage: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 18)
            } else {
                Button {
                    requestExplanation()
                } label: {
                    Label("What might explain this?", systemImage: "sparkles")
                }
                .font(.caption.weight(.medium))
                .padding(.leading, 18)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                Text("Thinking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 18)
        case .ready(let text):
            VStack(alignment: .leading, spacing: 4) {
                Label("What might explain this", systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("AI-generated possibility, not medical advice.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 18)
        case .error(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Try again") { requestExplanation() }
                    .font(.caption)
            }
            .padding(.leading, 18)
        }
    }

    private func requestExplanation() {
        explanationState = .loading
        Task {
            do {
                let text = try await narrator.explain(insight)
                explanationState = .ready(text)
            } catch {
                explanationState = .error("Couldn't generate an explanation right now.")
            }
        }
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

// MARK: - Scores row (Strain / Sleep / Activeness)

/// The three headline 0-100 scores, side by side, deliberately rendered as
/// rings rather than icon tiles — Strain, Sleep, and Activeness now share
/// exactly the same visual language and the same scoring scale (personal
/// baseline percentile, or TRIMP for Strain), instead of Strain being the
/// only metric with a "score" and Sleep/Steps only showing a raw value.
private struct ScoresRow: View {
    let strainScore: Double
    let sleepScore: Double?
    let sleepSubtitle: String
    let activenessScore: Double?
    let activenessSubtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ScoreTile(title: "Strain", score: strainScore, tint: .orange, subtitle: "today")
            ScoreTile(title: "Sleep", score: sleepScore, tint: .indigo, subtitle: sleepSubtitle)
            ScoreTile(title: "Activeness", score: activenessScore, tint: .green, subtitle: activenessSubtitle)
        }
    }
}

private struct ScoreTile: View {
    let title: String
    /// `nil` means "not enough personal-baseline history yet" — shown as an
    /// empty ring and a dash rather than a fabricated number.
    let score: Double?
    let tint: Color
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.15), lineWidth: 6)
                if let score {
                    Circle()
                        .trim(from: 0, to: max(0, min(1, score / 100)))
                        .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(score.map { "\(Int($0.rounded()))" } ?? "–")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
            }
            .frame(width: 58, height: 58)
            VStack(spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Vitals row (the richer Garmin metrics)

/// HRV, VO2 Max, Body Battery, Stress, Blood Oxygen, Respiration — shown
/// only when actually present, since not every source/day produces them,
/// and don't (yet) have a personal-baseline score model of their own the
/// way Strain/Sleep/Activeness do, so they're shown as plain values.
private struct VitalsRow: View {
    let latestSnapshot: DailyHealthSnapshot?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if let hrv = latestSnapshot?.heartRateVariability {
                    VitalTile(symbol: "waveform.path.ecg", tint: .pink, value: "\(Int(hrv.rounded()))", label: "HRV")
                }
                if let vo2Max = latestSnapshot?.vo2Max {
                    VitalTile(symbol: "lungs.fill", tint: .teal, value: String(format: "%.1f", vo2Max), label: "VO2 Max")
                }
                if let bodyBattery = latestSnapshot?.bodyBattery {
                    VitalTile(symbol: "battery.75", tint: .mint, value: "\(Int(bodyBattery.rounded()))", label: "Body Battery")
                }
                if let stress = latestSnapshot?.stress {
                    VitalTile(symbol: "brain.head.profile", tint: .purple, value: "\(Int(stress.rounded()))", label: "Stress")
                }
                if let spo2 = latestSnapshot?.bloodOxygen {
                    VitalTile(symbol: "drop.fill", tint: .blue, value: "\(Int((spo2 * 100).rounded()))%", label: "Blood Oxygen")
                }
                if let respiration = latestSnapshot?.respirationRate {
                    VitalTile(symbol: "wind", tint: .cyan, value: String(format: "%.0f", respiration), label: "Respiration")
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct VitalTile: View {
    let symbol: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            // A fixed icon frame with .fit scaling normalizes wildly
            // different SF Symbol glyph geometries (e.g. "wind" is a thin
            // wide glyph, "battery.75" is a wide pill, "drop.fill" is tall
            // and narrow) to the same optical footprint, rather than each
            // symbol rendering at its own natural size at a shared font.
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
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

//
//  DashboardView.swift
//  HealthIntelligence
//
//  Minimal dashboard built around the three future primary dimensions:
//  Strain, Sleep, Activeness. Shows whatever facts HealthAnalyzer currently
//  produces; scoring/insight language comes in a later milestone.
//

import SwiftUI

struct DashboardView: View {
    @State private var viewModel: DashboardViewModel
    @State private var insightsViewModel: InsightsViewModel
    @State private var importViewModel: ImportViewModel
    @State private var isImportPresented = false

    init(viewModel: DashboardViewModel, insightsViewModel: InsightsViewModel, importViewModel: ImportViewModel) {
        _viewModel = State(initialValue: viewModel)
        _insightsViewModel = State(initialValue: insightsViewModel)
        _importViewModel = State(initialValue: importViewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    content
                    InsightsSection(state: insightsViewModel.state)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Overview")
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

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            loadingView
        case .ready(let data):
            VStack(spacing: 16) {
                StrainCard(analysis: data.strain)
                SleepCard(analysis: data.sleep)
                ActivityCard(analysis: data.activity)
            }
        case .noData:
            statusView(
                symbol: "heart.text.square",
                title: "No Health Data Found",
                message: "Make sure Health access is granted for this app in Settings, and that your Garmin has synced recent data to Apple Health."
            )
        case .error(let message):
            statusView(symbol: "exclamationmark.triangle", title: "Something Went Wrong", message: message)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading Health data…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private func statusView(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await viewModel.load() } }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

// MARK: - Dimension cards

private struct DimensionCard<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
    }
}

private struct StrainCard: View {
    let analysis: StrainAnalysis

    var body: some View {
        DimensionCard(title: "Strain", symbol: "bolt.heart", tint: .orange) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(analysis.strain.strainScore, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("/ 100")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if analysis.strain.confidence == .low {
                    Text("Low Confidence")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: Capsule())
                }
            }
            MetricRow(label: "Total TRIMP (raw)", value: analysis.strain.totalTRIMP.formatted(.number.precision(.fractionLength(1))))

            if !analysis.strain.zoneBreakdownMinutes.isEmpty {
                HeartRateZoneBreakdownView(breakdown: analysis.strain.zoneBreakdownMinutes)
            }

            Divider().padding(.vertical, 2)

            if let rhr = analysis.restingHeartRate {
                MetricRow(label: "Resting Heart Rate", value: "\(Int(rhr.rounded())) bpm")
                if let deviation = analysis.percentageDeviationFromBaseline {
                    DeviationRow(deviation: deviation, unit: "vs. 30-day baseline")
                } else {
                    PlaceholderRow(text: "Building your baseline — check back in a few days.")
                }
            } else {
                PlaceholderRow(text: "No resting heart rate recorded today yet.")
            }

            if !analysis.workouts.isEmpty {
                Divider().padding(.vertical, 2)
                MetricRow(label: "Workouts Today", value: "\(analysis.workouts.count)")
            }
        }
    }
}

private struct HeartRateZoneBreakdownView: View {
    let breakdown: [HeartRateZone: Double]

    private static let order: [HeartRateZone] = [.zone80to100, .zone60to80, .zone40to60, .zone20to40, .zone0to20]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.order.filter { (breakdown[$0] ?? 0) > 0 }, id: \.self) { zone in
                HStack {
                    Text(label(for: zone))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((breakdown[zone] ?? 0).rounded())) min")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }

    private func label(for zone: HeartRateZone) -> String {
        switch zone {
        case .zone0to20: "0–20% HRR"
        case .zone20to40: "20–40% HRR"
        case .zone40to60: "40–60% HRR"
        case .zone60to80: "60–80% HRR"
        case .zone80to100: "80–100% HRR"
        }
    }
}

private struct SleepCard: View {
    let analysis: SleepAnalysis

    var body: some View {
        DimensionCard(title: "Sleep", symbol: "moon.zzz", tint: .indigo) {
            if let asleep = analysis.totalTimeAsleep, asleep > 0 {
                MetricRow(label: "Time Asleep", value: Self.formatted(asleep))
                if let inBed = analysis.totalTimeInBed {
                    MetricRow(label: "Time in Bed", value: Self.formatted(inBed))
                }
                if !analysis.stageBreakdown.isEmpty {
                    SleepStageBreakdownView(breakdown: analysis.stageBreakdown)
                }
            } else {
                PlaceholderRow(text: "No sleep data found for last night.")
            }
        }
    }

    private static func formatted(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}

private struct SleepStageBreakdownView: View {
    let breakdown: [SleepStage: TimeInterval]

    private static let order: [SleepStage] = [.rem, .core, .deep, .awake, .unspecified, .inBed]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.order.filter { breakdown[$0] != nil }, id: \.self) { stage in
                if let duration = breakdown[stage] {
                    HStack {
                        Text(label(for: stage))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(duration / 60)) min")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func label(for stage: SleepStage) -> String {
        switch stage {
        case .inBed: "In Bed"
        case .awake: "Awake"
        case .core: "Core"
        case .deep: "Deep"
        case .rem: "REM"
        case .unspecified: "Asleep"
        }
    }
}

private struct ActivityCard: View {
    let analysis: ActivityAnalysis

    var body: some View {
        DimensionCard(title: "Activeness", symbol: "figure.walk", tint: .green) {
            MetricRow(label: "Steps Today", value: "\(Int(analysis.totalStepsToday))")
            if analysis.totalActiveEnergyToday > 0 {
                MetricRow(label: "Active Energy", value: "\(Int(analysis.totalActiveEnergyToday)) kcal")
            }
            if let deviation = analysis.percentageDeviationFromBaseline {
                DeviationRow(deviation: deviation, unit: "vs. 30-day baseline")
            } else {
                PlaceholderRow(text: "Building your baseline — check back in a few days.")
            }
        }
    }
}

// MARK: - Insights

private struct InsightsSection: View {
    let state: InsightsViewModel.State

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Insights")
                .font(.headline)
                .padding(.horizontal, 4)

            switch state {
            case .idle, .loading:
                DimensionCard(title: "Analyzing", symbol: "sparkles", tint: .purple) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking for patterns in your recent history…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .buildingBaseline:
                DimensionCard(title: "Building Your Baseline", symbol: "chart.line.uptrend.xyaxis", tint: .purple) {
                    PlaceholderRow(text: "Insights need at least \(MetricBaseline.minimumReliableSampleCount) days of Health history — check back soon.")
                }
            case .ready(let insights) where insights.isEmpty:
                DimensionCard(title: "All Normal", symbol: "checkmark.circle", tint: .purple) {
                    PlaceholderRow(text: "Nothing stands out from your recent baseline.")
                }
            case .ready(let insights):
                ForEach(insights) { insight in
                    InsightCard(insight: insight)
                }
            case .error(let message):
                DimensionCard(title: "Insights Unavailable", symbol: "exclamationmark.triangle", tint: .purple) {
                    PlaceholderRow(text: message)
                }
            }
        }
    }
}

private struct InsightCard: View {
    let insight: HealthInsight

    var body: some View {
        DimensionCard(title: insight.title, symbol: "sparkles", tint: tint(for: insight.severity)) {
            Text(insight.narrative)
                .font(.subheadline)
            HStack {
                Text(insight.severity.label)
                Spacer()
                Text("\(Int((insight.confidence * 100).rounded()))% confidence")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func tint(for severity: SignalSeverity) -> Color {
        switch severity {
        case .info: .blue
        case .mild: .yellow
        case .moderate: .orange
        case .significant: .red
        }
    }
}

// MARK: - Shared row views

private struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }
}

private struct DeviationRow: View {
    let deviation: Double
    let unit: String

    var body: some View {
        HStack {
            Image(systemName: deviation >= 0 ? "arrow.up.right" : "arrow.down.right")
            Text("\(deviation >= 0 ? "+" : "")\(deviation, specifier: "%.0f")% \(unit)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct PlaceholderRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
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

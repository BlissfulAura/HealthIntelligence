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

    init(viewModel: DashboardViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Overview")
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
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
    DashboardView(viewModel: DashboardViewModel(healthKitService: HealthKitService()))
}

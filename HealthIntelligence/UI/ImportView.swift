//
//  ImportView.swift
//  HealthIntelligence
//
//  The Import Data screen: pick a ZIP, watch it import, see what was found.
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @State private var viewModel: ImportViewModel
    @State private var isPickerPresented = false
    @Environment(\.dismiss) private var dismiss

    init(viewModel: ImportViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import Data")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
                .fileImporter(isPresented: $isPickerPresented, allowedContentTypes: [.zip]) { result in
                    if case .success(let url) = result {
                        Task { await viewModel.import(from: url) }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            emptyState
        case .importing:
            importingState
        case .done(let summary):
            ImportSummaryView(summary: summary) { viewModel.reset() }
        case .failed(let message):
            failedState(message: message)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Import a \(viewModel.sourceDisplayName)")
                .font(.headline)
            Text("Request a full data export from Garmin Connect (Account Settings → Export Your Data), then select the downloaded ZIP file here. The entire export is inspected automatically — no need to pick individual files.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Choose ZIP File") { isPickerPresented = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var importingState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Reading your export…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("This can take a while for a large export, especially heart rate and sleep history.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Import Failed")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Try Again") { viewModel.reset() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct ImportSummaryView: View {
    let summary: ImportSummary
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("Import Complete")
                        .font(.headline)
                    if let range = summary.dateRange {
                        Text("\(range.lowerBound.formatted(date: .abbreviated, time: .omitted)) – \(range.upperBound.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top)

                if summary.totalImported > 0 {
                    section(title: "Imported", counts: summary.importedCounts)
                } else {
                    Text("Nothing new was found to import — everything in this export may already be in Health.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                if summary.totalSkippedDuplicates > 0 {
                    section(title: "Already Present (Skipped)", counts: summary.skippedDuplicateCounts)
                }

                if summary.unrecognizedFileCount > 0 {
                    HStack {
                        Text("Not Recognized")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(summary.unrecognizedFileCount) file(s)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .padding(.horizontal)
                }

                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .padding(.top)
            }
            .padding()
        }
    }

    private func section(title: String, counts: [ImportedDataCategory: Int]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(ImportedDataCategory.allCases.filter { (counts[$0] ?? 0) > 0 }, id: \.self) { category in
                HStack {
                    Text(category.displayName)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(counts[category] ?? 0)")
                        .monospacedDigit()
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    ImportView(viewModel: ImportViewModel(source: GarminExportImporter(healthKitService: HealthKitService())))
}

//
//  ImportViewModel.swift
//  HealthIntelligence
//
//  Drives the Import Data screen: presents a file picker, hands the picked
//  ZIP to a HealthDataImportSource, and exposes the resulting state. Owns
//  no ZIP/JSON parsing or HealthKit logic itself — that's
//  GarminExportImporter's job, reached only through the
//  HealthDataImportSource protocol so this view model doesn't care which
//  source it's driving.
//

import Foundation
import Observation

@Observable
final class ImportViewModel {
    enum State {
        case idle
        case importing
        case done(ImportSummary)
        case failed(String)
    }

    private(set) var state: State = .idle

    private let source: HealthDataImportSource

    init(source: HealthDataImportSource) {
        self.source = source
    }

    var sourceDisplayName: String { source.sourceDisplayName }

    func `import`(from url: URL) async {
        state = .importing
        do {
            let summary = try await source.import(from: url)
            state = .done(summary)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func reset() {
        state = .idle
    }
}

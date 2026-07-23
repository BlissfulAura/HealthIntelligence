//
//  HealthInsightNarrator.swift
//  HealthIntelligence
//
//  A deliberately separate, optional layer on top of the deterministic
//  pipeline (HealthInsightEngine and everything upstream of it stay
//  no-LLM, exactly as documented in HealthInsight.swift). Everything this
//  app tells the user by default is arithmetic over their own history —
//  this file only generates a *possible, speculative* everyday explanation
//  for why a detected pattern might be happening, on explicit request, and
//  is always labeled as such in the UI (see InsightFeedCard).
//
//  Uses Apple's on-device Foundation Models framework (iOS 26+) rather than
//  a cloud LLM API: no health data ever leaves the device, no network
//  round-trip, no API key — consistent with the rest of the app's
//  privacy-first design. Requires the device to support Apple Intelligence
//  and the user to have it enabled in Settings; `availability` surfaces
//  that state so the UI can explain it instead of the feature silently
//  failing.
//

import Foundation
import FoundationModels

struct HealthInsightNarrator {
    enum Availability {
        case available
        /// A short, user-facing reason it isn't available right now.
        case unavailable(String)
    }

    var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable("This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in Settings to get AI-generated explanations.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still getting ready on this device — try again shortly.")
        @unknown default:
            return .unavailable("AI-generated explanations aren't available right now.")
        }
    }

    /// Deliberately constrains the model to speculative, non-medical,
    /// everyday explanations grounded only in the evidence it's given —
    /// never a diagnosis, never framed as certain.
    private static let instructions = """
    You help someone understand possible everyday reasons a personal \
    health-tracking metric might be trending the way it is. You are not a \
    medical professional. Never diagnose a condition, never claim \
    certainty, and never give medical advice. Given a detected pattern and \
    the numeric evidence behind it, suggest 2-3 brief, plausible, common \
    lifestyle explanations (for example: training load, travel, alcohol, \
    poor sleep, a schedule change, stress, hydration, or illness). Keep the \
    whole reply under 80 words, write in plain conversational language, and \
    frame every explanation as a possibility to consider, not a \
    conclusion. If the evidence given is too thin to say anything useful, \
    say so plainly instead of guessing.
    """

    func explain(_ insight: HealthInsight) async throws -> String {
        let session = LanguageModelSession(instructions: Self.instructions)
        let prompt = """
        Detected: \(insight.title)
        What this means: \(insight.narrative)
        Evidence:
        \(insight.evidence.isEmpty ? "(no additional evidence)" : insight.evidence.joined(separator: "\n"))
        """
        let response = try await session.respond(to: prompt)
        return response.content
    }
}

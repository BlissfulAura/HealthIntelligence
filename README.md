# Health Intelligence

Private, personalized health insights — powered entirely on your iPhone.

Health Intelligence is a privacy-first iOS application that transforms Apple Health data into meaningful, personalized insights using on-device analytics and AI inference.
Health Intelligence reads what's already in Apple Health (including the subset of data your Garmin, Apple Watch, or other wearable syncs there), analyzes it entirely on-device, and will surface three personalized assessments: **Strain**, **Sleep**, and **Activeness** — each measured against your own historical baseline, not an arbitrary target.

All core processing is designed to happen locally on the user's device.

No health data needs to be sent to an external AI service.
No cloud inference is required.
No recurring AI subscription is required.


This repository currently contains the foundational architecture and data pipeline: HealthKit integration, a HealthKit-independent data model, and the analysis/presentation layers wired end-to-end. The scoring algorithms themselves are the next milestone — see [Roadmap](#roadmap).

---

## The problem

Most fitness and recovery apps score you against a generic target: 10,000 steps, 8 hours of sleep, a "normal" resting heart rate for your age. That's a poor fit for anyone whose baseline doesn't match the population median — a resting heart rate of 48 bpm might be a warning sign for one person and completely normal for a lifetime endurance athlete.

Wearable platforms that *do* personalize (Garmin's Body Battery, HRV Status, Stress Score) are locked inside their own ecosystems and don't reliably expose that reasoning — or the underlying data — to other apps. Garmin devices sync only a limited slice of their data into Apple Health, so an app built for the Apple Health ecosystem has to work with heart rate, steps, energy, and sleep stages — and nothing Garmin-proprietary like HRV Status or Body Battery.

Health Intelligence is built around that constraint rather than against it: use exactly what HealthKit actually exposes, and build personalization on top of it rather than assuming access to data that isn't there.

## Why "Strain," not "Stress"

This project deliberately avoids the word "stress." Estimating autonomic or psychological stress credibly really wants heart rate variability (HRV), and HRV is not reliably part of what wearables sync into Apple Health. Rather than fake precision with insufficient data, the app measures **Strain**: how physiologically taxed the user appears, based on signals HealthKit can actually provide (heart rate deviation, recent activity load). It's a narrower, more honest claim than "stress," and the naming is intended to keep the analysis layer honest as it grows.

The same philosophy applies everywhere: the analyzer is designed to produce facts ("resting heart rate is 8% above your 30-day baseline"), not diagnoses ("you are stressed" or "you slept badly").

## Vision

Three personalized dimensions, each measured relative to the user's own history:

| Dimension | Question it answers |
|---|---|
| **Strain** | How physiologically taxed does the user appear relative to their personal baseline? |
| **Sleep** | How well did the user sleep and recover, based on their own patterns? |
| **Activeness** | How physically active has the user been relative to their normal activity? |

All analysis runs on-device. No health data leaves the phone — there is no backend, no analytics SDK, and no third-party network dependency in this project.

---

## Current status

| Layer | Status |
|---|---|
| HealthKit integration (auth, queries, unit conversion) | Implemented |
| HealthKit-independent data models | Implemented |
| Dashboard UI, state management, view model | Implemented |
| Deterministic foundations (baseline averages, % deviation) | Implemented |
| Strain / Sleep / Activeness scoring algorithms | Not yet — see [Roadmap](#roadmap) |
| On-device personalized insight generation | Not yet |

In short: the pipe is fully connected from Apple Health to the screen. What flows through it today is real data and simple, honest math — not yet a scoring model.

---

## Architecture

The project intentionally uses a small number of layers. No repositories, use-case classes, coordinators, or DI framework — each concern gets exactly one file until there's a concrete reason to split it further.

```text
HealthIntelligence/
│
├── Health/
│   ├── HealthKitService.swift   — HealthKit boundary: auth, queries, unit conversion
│   └── HealthModels.swift       — App-level data model, no HealthKit dependency
│
├── Intelligence/
│   └── HealthAnalyzer.swift     — Deterministic analysis: facts, not conclusions
│
└── UI/
    ├── HealthIntelligenceApp.swift  — Composition root
    ├── DashboardViewModel.swift     — Orchestrates fetch → analyze → state
    └── DashboardView.swift          — SwiftUI presentation
```

### Data pipeline

```mermaid
flowchart LR
    A[Apple Health] --> B[HealthKitService]
    B --> C[Health Models]
    C --> D[HealthAnalyzer]
    D --> E[DashboardViewModel]
    E --> F[DashboardView]
```

Each stage has one job and depends only on the interface of the stage before it:

- **HealthKitService** talks to `HKHealthStore` and nothing else touches `HKSample`, `HKQuantityType`, or any other HealthKit type. It converts every result into a plain Swift model before returning.
- **Health Models** (`HealthMetricSample`, `SleepSession`, etc.) are pure value types. They know nothing about HealthKit and could back a different data source entirely.
- **HealthAnalyzer** is a stateless, deterministic transformer: models in, structured analysis out. No HealthKit imports, no UI imports — fully unit-testable in isolation.
- **DashboardViewModel** coordinates the two but owns no query logic and no analysis math itself — it fetches, hands data to the analyzer, and maps the result to view state.
- **DashboardView** renders whatever state it's given.

### Why this shape

The layering is deliberately shallow because the *hard* part of this app isn't architectural — it's getting the health analysis right. A thin, obvious pipeline keeps the surface area small so that effort can go into the analyzer once real scoring work starts, instead of into maintaining abstractions the project doesn't need yet (generic repositories, protocol-oriented DI, use-case objects). Every layer exists because something concrete requires it:

- HealthKit types are UIKit-era, completion-handler-shaped, and not `Sendable` — isolating them behind one service keeps that mess from leaking into analysis or UI code, and keeps the analyzer testable with plain structs instead of mocked `HKHealthStore` calls.
- Sleep gets first-class model types (`SleepStage`, `SleepStageSegment`, `SleepSession`) because its structure is fundamentally different from a scalar metric; heart rate, steps, and both energy types share `HealthMetricSample` because they're all "a number over a time interval" and a separate type per metric would be pure duplication.

---

## Engineering challenges and tradeoffs

A few decisions worth calling out for anyone reading the code closely:

**HealthKit's read-permission privacy model.** `HKHealthStore.authorizationStatus(for:)` only returns meaningful state for *write* permissions. For read-only types — everything this app requests — HealthKit deliberately withholds whether access was granted or denied, to prevent an app from inferring sensitive health facts purely from permission state. Practical consequence: the app cannot show a "please grant access" screen with any certainty. Instead, it always issues the authorization request (a no-op if the user already decided) and attempts the fetch; if every query comes back empty, that's surfaced as one ambiguous `.noData` state — deliberately not claimed to mean "denied," because it might just mean "no data yet."

**Sleep-session grouping is a heuristic, not a HealthKit guarantee.** Multiple sources (a Garmin watch and an iPhone, say) can write overlapping or gapped sleep-stage samples for the same night. `HealthKitService` groups raw stage segments into sessions using a time-proximity heuristic (segments within an hour of each other belong to the same night) rather than trusting any single source's session boundaries. This is the kind of assumption that needs to be validated against real multi-source data, not just Simulator data.

**Garmin's data is a black box from HealthKit's side.** There's no way to know in advance whether a given Garmin device writes detailed sleep stages (`core`/`deep`/`rem`) or only a generic "asleep" value — that's entirely up to Garmin's HealthKit writer. The model includes `SleepStage.unspecified` specifically to degrade gracefully when stage-level detail isn't available, rather than assuming it always will be.

**Modern concurrency without ceremony.** The target enables `SWIFT_APPROACHABLE_CONCURRENCY` and defaults actor isolation to `MainActor`. Combined with `HKSampleQueryDescriptor`'s async `result(for:)` API, this means HealthKit queries are `async/await` end-to-end with no completion-handler wrapping and no manual `Sendable` bookkeeping — while still converting every HealthKit object to a plain value type at the service boundary rather than passing `HKSample` around.

---

## Tech stack

- **Swift 5** (approachable concurrency mode, `async/await` throughout)
- **SwiftUI** with the `@Observable` macro (`Observation` framework) for view state
- **HealthKit**, queried via `HKSampleQueryDescriptor`'s async API
- No third-party dependencies

## Project structure

```text
HealthIntelligence/
├── HealthIntelligence.xcodeproj/
└── HealthIntelligence/
    ├── HealthIntelligenceApp.swift
    ├── HealthIntelligence.entitlements
    ├── Health/
    │   ├── HealthKitService.swift
    │   └── HealthModels.swift
    ├── Intelligence/
    │   └── HealthAnalyzer.swift
    ├── UI/
    │   ├── DashboardViewModel.swift
    │   └── DashboardView.swift
    └── Assets.xcassets/
```

## Getting started

**Requirements**

- Xcode 26+
- iOS 26+ device or Simulator (a physical device is required to see real Health data — the Simulator has none by default)
- An Apple Health source with some data in it (Apple Watch, iPhone, or a connected wearable like Garmin)

**Run it**

```bash
git clone <repo-url>
cd HealthIntelligence
open HealthIntelligence.xcodeproj
```

Select your development team in the target's Signing & Capabilities tab, then build and run on a physical device. On first launch, grant Health access when prompted — the dashboard populates from whatever heart rate, step, energy, and sleep data your Health app already has.

---

## Roadmap

The next milestone is the actual analysis layer:

1. **Personal baselines with persistence.** Rolling N-day baselines need to be computed and cached locally (likely SwiftData) rather than re-querying HealthKit's full history on every launch.
2. **Strain scoring** — combining resting heart rate deviation with recent activity load into a single, explainable measure.
3. **Sleep scoring** — duration, fragmentation, and stage distribution relative to the user's own historical patterns.
4. **Activeness scoring** — steps and active energy combined, relative to baseline, rather than steps in isolation.
5. **On-device personalized insights** — natural-language summaries generated locally from the structured analysis output, once the underlying facts are trustworthy.

Every future addition should keep slotting into the existing `analyze...` functions in `HealthAnalyzer` without changing the pipeline's shape.

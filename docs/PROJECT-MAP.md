# iMetaClaw Project Map

> **AIOX Enterprise brownfield project map** — single source of truth for status, plans, gaps, and next actions.  
> Synthesized from: `enhance-workflow` (Discovery → Epic), `governance-pipeline` (Gap Analysis), `IDS` (REUSE → ADAPT → CREATE), and session work (Jun 24–25, 2026).

```yaml
meta:
  project_id: imetaclaw-phase1
  product_name: iMetaClaw
  domain: imetaclaw.com
  repository: /Volumes/aiagents2TB/Dev/GITHUB/OpenGlasses
  upstream: OpenGlasses (Skunkworks NZ / straff2002)
  fork_owner: Renata Baldissara-Kunnela (renatbk@gmail.com)
  apple_team: VF88UK56C3
  bundle_id: com.clawglasses.app
  agent_vps: Hostinger kmv2 — OpenClaw agent "Maia" + Telegram bot
  market: Brazil (pt-BR) + international (en)
  strategy: Phase 1 quick wins on iOS fork → Phase 2 iMetaClaw stripped fork → Phase 3 Android thin client
  map_version: "1.0.0"
  last_updated: "2026-06-25"
  map_author: Grok (session) + Manus (sessions 1–3)
  status_overall: IN_PROGRESS — Phase 1 ~35% complete
```

---

## 1. Executive Summary

**iMetaClaw** is a simplified iOS companion for Ray-Ban Meta glasses that connects to an **OpenClaw agent on a VPS** (e.g. Maia on Hostinger). The phone is a voice + camera terminal; AI logic lives on the server.

The repo is a **brownfield fork** of upstream OpenGlasses (~400 Swift files, 85+ native tools). We are **not** rebuilding from scratch yet — Phase 1 adds branding, `Oi {bot}` wake phrase, agent settings, and fixes UX blockers while planning a stripped fork.

| Dimension | State |
|-----------|-------|
| **Build & install** | ✅ Builds on device (USB) |
| **Branding (iMetaClaw)** | 🚧 Done in working tree, not committed |
| **Maia / VPS connected** | ❌ Not configured end-to-end |
| **Sell-ready for Brazil** | ❌ Needs pt-BR completion, gateway wizard, simple mode |
| **TestFlight** | ❌ Not started |
| **Meta Wearables review** | ❌ Not registered |

---

## 2. IDS Compliance Check (REUSE → ADAPT → CREATE)

| Component | Decision | Notes |
|-----------|----------|-------|
| `OpenClawBridge` + gateway WebSocket | **REUSE** | Core VPS connection — do not rewrite |
| `AudioRecordingService` | **REUSE** | Discrete audio recording (no camera LED) |
| `LiveTranslationService` | **ADAPT** | Shell exists; `translate()` is stub — needs LLM or Apple Translation |
| `AmbientCaptionService` | **REUSE** | Live meeting transcript |
| `ModelFormView` OAuth (Claude) | **REUSE** | Subscription login in Settings (commit `a30e20c`) |
| `LocalizationManager` + `Localizable.xcstrings` | **ADAPT** | pt-BR entries exist; most UI still hardcoded English |
| Upstream 85+ native tools | **ADAPT** | Hide via `simpleMode` — don't delete yet |
| Onboarding (7→8 pages) | **ADAPT** | Agent name step added (uncommitted) |
| Gateway onboarding wizard | **CREATE** | Users cannot configure VPS from terminal |
| Pairing QR (`imetaclaw://connect?...`) | **CREATE** | Reseller / full-stack sales flow |
| `RecordingSettingsView` | **CREATE** | Recording + translation hub in Settings |
| `simpleMode` feature flag | **CREATE** | Hide 90% of upstream features |
| VPS `openclaw install imetaclaw-bridge` | **CREATE** | Server-side pairing code generator |
| Android thin client | **DEFERRED** | After iOS sells; shared protocol doc first |
| Flutter/RN cross-platform UI | **REJECTED** | Meta Wearables DAT SDK is iOS-native |

**CREATE rate estimate:** ~25% of Phase 1 scope — within AIOX target (<30%).

---

## 3. Architecture (Target State)

```
Ray-Ban Meta Glasses
        │ Bluetooth audio (+ optional camera)
        ▼
iMetaClaw iOS App (thin client)
  • Wake: "Oi {botName}"  (e.g. Oi Maia)
  • Speech → text → OpenClaw gateway
  • TTS response → glasses speaker
  • Optional: audio-only record + live PT↔EN translation
  • Optional: user AI APIs (Advanced mode)
        │ HTTPS / WebSocket (Bearer token)
        ▼
Hostinger VPS (or any host)
  • OpenClaw Gateway (:18789)
  • Maia agent
  • Telegram bot (same agent)
  • Claude / Grok / skills (server-side)
```

**Hard constraint:** Video/photo capture on Ray-Ban Meta **always triggers hardware capture LED** — cannot be disabled by third-party apps. **Discrete recording = audio-only only.**

---

## 4. Epic: iMetaClaw Phase 1

| Field | Value |
|-------|-------|
| **Objective** | Ship a configurable, Brazilian-friendly OpenClaw glasses client resellers can sell |
| **In scope** | Branding, Oi-wake, agent settings, paste fix, gateway UX, simple mode, recording settings, PT/EN translation, optional user AI |
| **Out of scope** | Full fork rename, Android, TestFlight production, Meta App Store approval, video without LED |
| **Success metrics** | User completes onboarding without terminal; says "Oi Maia" and gets VPS response; pt-BR onboarding readable; paste works for API keys |

### MoSCoW Priority

| Priority | Items |
|----------|-------|
| **Must** | Gateway wizard, paste buttons, `simpleMode`, Maia connection test, pt-BR core strings |
| **Should** | Recording settings, live PT↔EN translation fix, pairing QR, OAuth in onboarding |
| **Could** | TestFlight beta, voice commands PT, watch icon update |
| **Won't (Phase 1)** | Android, strip all upstream code, Meta production approval |

---

## 5. Work Item Registry

Status legend: ✅ Done · 🚧 In progress / uncommitted · 📋 Planned · ❌ Not started · ⚠️ Blocked · 🔍 Gap

### Wave 0 — Foundation & Infrastructure

| ID | Item | Status | Evidence / Notes |
|----|------|--------|------------------|
| W0.1 | Apple Developer account active | ✅ Done | Team `VF88UK56C3`, paid Jun 24, 2026 |
| W0.2 | ClawGlasses bundle IDs (`com.clawglasses.app`) | ✅ Done | `project.local.yml` |
| W0.3 | Login keychain + codesign fixes | ✅ Done | AGENTS.md §6.1–6.2 |
| W0.4 | Watch widget bundle ID prefix | ✅ Done | `com.clawglasses.app.watchapp.watchwidget` |
| W0.5 | `WKCompanionAppBundleIdentifier` | ✅ Done | `OpenGlassesWatch/Info.plist` |
| W0.6 | `Info.personal.plist` full CFBundle keys | ✅ Done | Merged with MWDAT |
| W0.7 | App builds & installs on iPhone | ✅ Done | Device `40727801-…` |
| W0.8 | `AGENTS.md` handoff doc | ✅ Done | Commit `854ae74` |
| W0.9 | xAI/Grok `LLMProvider` | ✅ Done | Commit `88e8d19` |
| W0.10 | SecureField → TextField (13 fields) | ✅ Done | Commit `a30e20c` |
| W0.11 | Paste buttons on token fields | ✅ Done | Commit `a30e20c` (Manus session 3) |
| W0.12 | Claude OAuth in ModelFormView | ✅ Done | Commit `a30e20c` |
| W0.13 | pt-BR in `Localizable.xcstrings` | 🚧 Partial | Commit `a30e20c` — many views still hardcoded EN |

### Wave 1 — iMetaClaw Branding & Agent Identity

| ID | Item | Status | Evidence / Notes |
|----|------|--------|------------------|
| W1.1 | Product name **iMetaClaw** | 🚧 Uncommitted | `AppBranding.swift`, `project.local.yml` display name |
| W1.2 | App icon (light + dark 1024) | 🚧 Uncommitted | `AppIcon.appiconset/*.png` |
| W1.3 | In-app logo asset | 🚧 Uncommitted | `iMetaClawLogo.imageset/` |
| W1.4 | Launch screen branding | 🚧 Uncommitted | `LaunchScreen.swift` |
| W1.5 | Onboarding branding + agent page | 🚧 Uncommitted | `OnboardingView.swift` — 8 pages, "Seu agente" |
| W1.6 | **`Oi {botName}` wake phrase** | 🚧 Uncommitted | `Config.agentName`, `AppBranding.wakePhrase(for:)` |
| W1.7 | Fuzzy alternatives (`oy`, `oí`, `hoy`) | 🚧 Uncommitted | `Config.defaultAlternativesForPhrase` |
| W1.8 | Wake phrase migration from `hey openglasses` | 🚧 Uncommitted | `Config.migrateToIMetaClawWakePhraseIfNeeded()` |
| W1.9 | `AgentSettingsView` (name + gateway link) | 🚧 Uncommitted | New file, not in git |
| W1.10 | Settings → Seu agente section | 🚧 Uncommitted | `SettingsView.swift` |
| W1.11 | OnboardingOverlay pt-BR strings | 🚧 Uncommitted | `OnboardingOverlay.swift` |

### Wave 2 — OpenClaw Connection (Maia / VPS)

| ID | Item | Status | Evidence / Notes |
|----|------|--------|------------------|
| W2.1 | `OpenClawBridge` client (health + WebSocket) | ✅ Done | Upstream — REUSE |
| W2.2 | `GatewaySettingsView` (URL + token) | ✅ Done | Upstream — expert UI, buried in Settings |
| W2.3 | Gateway wizard in **onboarding** | 📋 Planned | Users need in-app setup, not terminal |
| W2.4 | Test connection button in onboarding | 📋 Planned | `OpenClawBridge.checkConnection()` exists |
| W2.5 | Pairing QR parser `imetaclaw://connect?...` | 📋 Planned | Full-stack / reseller flow |
| W2.6 | **Maia connected end-to-end** | ❌ Not started | Needs VPS URL + gateway token from user |
| W2.7 | VPS `imetaclaw-bridge` install script | 📋 Planned | Server-side pairing code generation |
| W2.8 | Hostinger API auto-discovery | 🔍 Gap | Hostinger token ≠ OpenClaw gateway token |

### Wave 3 — Simplification (`simpleMode`)

| ID | Item | Status | Evidence / Notes |
|----|------|--------|------------------|
| W3.1 | `Config.simpleMode` flag | 📋 Planned | Hide Field Assist, Medical, MCP catalog, etc. |
| W3.2 | Tool whitelist (OpenClaw + camera + translate) | 📋 Planned | ~8–12 tools vs 85+ |
| W3.3 | Simplified Settings navigation | 📋 Planned | ~10 items vs 50+ |
| W3.4 | Onboarding skips API key (gateway-only path) | 📋 Planned | AI runs on VPS |
| W3.5 | Advanced mode toggle for power users | 📋 Planned | APIs, subscriptions, full tool list |
| W3.6 | Full iMetaClaw fork (strip codebase) | 📋 Phase 2 | Option B — separate target |

### Wave 4 — Recording & Translation (User Requirements)

| ID | Item | Status | Evidence / Notes |
|----|------|--------|------------------|
| W4.1 | Record **without camera LED** | ⚠️ Audio only | `AudioRecordingService` — REUSE; video always has LED |
| W4.2 | `RecordingSettingsView` in Settings | 📋 Planned | Not exposed to user today |
| W4.3 | Wire audio recording to Settings toggle | 📋 Planned | `AudioRecordingTool` exists |
| W4.4 | LED disclaimer in UI | 📋 Planned | Legal + honest UX |
| W4.5 | Live transcript during recording | ✅ Done upstream | `AmbientCaptionService` + `autoTranscribe` |
| W4.6 | Fix `LiveTranslationService.translate()` | 📋 Planned | **Stub** — returns `[lang→lang] text` only |
| W4.7 | PT ↔ EN language pair | 📋 Planned | `pt-BR` + `en` locales in translation settings |
| W4.8 | Meeting mode (record + translate + TTS) | 📋 Planned | Combine existing services |
| W4.9 | User optional AI subscriptions/APIs | 🚧 Partial | OAuth in Settings; not in onboarding |

### Wave 5 — Localization & Go-to-Market

| ID | Item | Status | Evidence / Notes |
|----|------|--------|------------------|
| W5.1 | Bundle pt-BR (not download-only) | 🚧 Partial | `LocalizationManager` lists pt-BR as downloadable |
| W5.2 | Translate onboarding + settings first | 🚧 Partial | Agent page PT; rest mixed |
| W5.3 | In-app language picker (PT / EN) | 📋 Planned | |
| W5.4 | Voice commands PT ("Oi Maia, grava") | 📋 Planned | |
| W5.5 | TestFlight beta group | ❌ Not started | |
| W5.6 | Meta for Developers + Wearables registration | ❌ Not started | Required for production |
| W5.7 | Reseller white-label / per-seat licensing | 📋 Planned | Business infra |
| W5.8 | Android thin client | 📋 Phase 3 | Voice terminal only |

---

## 6. Gap Analysis Matrix

| Gap | Severity | Impact | Resolution | Owner |
|-----|----------|--------|------------|-------|
| App assumes expert user (gateway jargon, 85 tools) | **P0** | Cannot sell to Brazilians | `simpleMode` + gateway wizard + pt-BR | Dev |
| Maia VPS not connected | **P0** | Core value prop broken | User provides URL + token; wizard + test | User + Dev |
| Paste blocked on iOS (reported) | **P1** | Cannot enter API keys | Fixed in `a30e20c` — verify on device | QA |
| `LiveTranslationService` stub | **P1** | Translation feature fake | Wire to LLM or Apple Translation framework | Dev |
| Video recording without LED | **P2** | User expectation | **Not possible** — document audio-only path | UX copy |
| Hostinger token ≠ gateway token | **P2** | Auto-config confusion | Pairing QR from VPS bridge, not Hostinger API | Dev + VPS |
| OAuth only in Settings, not onboarding | **P2** | Subscription users blocked early | Move OAuth to onboarding optional step | Dev |
| Most UI hardcoded English | **P1** | Brazil market | `String(localized:)` + xcstrings | Dev |
| Upstream complexity (400 files) | **P2** | Maintenance burden | Phase 2 stripped fork | Dev |
| Meta App Store / Wearables approval | **P2** | Production distribution | Register Meta app, submit for review | User |
| No TestFlight | **P2** | Cannot sell to customers | Archive + upload pipeline | Dev |
| Android absent | **P3** | Half of phone market | Phase 3 thin Kotlin client | Roadmap |
| `imetaclaw.com` DNS / landing | **P3** | Brand | Point domain to product page | User |

**Gap verdict:** Phase 1 can proceed — no architectural blockers. **P0 gaps** are UX and VPS connection, not missing libraries.

---

## 7. Upstream vs Fork — Feature Inventory

OpenGlasses upstream ships **85+ native tools**. iMetaClaw Phase 1 target: **~10 tools enabled** in simple mode.

| Category | Upstream | iMetaClaw Phase 1 |
|----------|----------|-------------------|
| OpenClaw gateway / skills | ✅ | ✅ **Core** |
| Voice wake + TTS | ✅ | ✅ **Core** |
| Glasses camera → agent | ✅ | ✅ **Core** |
| Audio-only recording | ✅ | ✅ **Add to Settings** |
| Live translation PT↔EN | 🚧 stub | ✅ **Fix + expose** |
| Local LLM / MLX | ✅ | ❌ Hide (VPS AI) |
| Field Assist / Medical / Study | ✅ | ❌ Hide |
| MCP catalog / 85 tools | ✅ | ❌ Hide (simple mode) |
| Personas / model routing | ✅ | ❌ Hide |
| Watch / CarPlay / Widgets | ✅ | ❌ Defer |

---

## 8. Key Files (Quick Reference)

| Purpose | Path |
|---------|------|
| Project handoff (build, fixes) | `AGENTS.md` |
| **This map** | `docs/PROJECT-MAP.md` |
| Branding constants | `OpenGlasses/Sources/Utils/AppBranding.swift` |
| Agent name + wake phrase | `OpenGlasses/Sources/Utils/Config.swift` |
| Agent settings UI | `OpenGlasses/Sources/App/Views/AgentSettingsView.swift` |
| Gateway connection | `OpenGlasses/Sources/Services/OpenClawBridge.swift` |
| Gateway settings | `OpenGlasses/Sources/App/Views/GatewaySettingsView.swift` |
| Onboarding | `OpenGlasses/Sources/App/Views/OnboardingView.swift` |
| Audio recording (discrete) | `OpenGlasses/Sources/Services/AudioRecordingService.swift` |
| Live translation (needs fix) | `OpenGlasses/Sources/Services/LiveTranslationService.swift` |
| App icon | `OpenGlasses/Sources/Resources/Assets.xcassets/AppIcon.appiconset/` |
| Logo | `OpenGlasses/Sources/Resources/Assets.xcassets/iMetaClawLogo.imageset/` |
| Local signing / display name | `project.local.yml` (gitignored) |
| Feature plans (upstream) | `docs/plans/README.md` |

---

## 9. Git & Commit State (2026-06-25)

| Commit | Description |
|--------|-------------|
| `854ae74` | `AGENTS.md` — full project context |
| `88e8d19` | xAI/Grok provider + switch fixes |
| `a30e20c` | Paste fix, Claude OAuth, pt-BR xcstrings (Manus session 3) |

**Uncommitted (iMetaClaw session — Grok):**

- `AppBranding.swift` (new)
- `AgentSettingsView.swift` (new)
- `iMetaClawLogo.imageset/` (new)
- `AppIcon` PNGs (new)
- Modified: `Config.swift`, `OnboardingView.swift`, `SettingsView.swift`, `LaunchScreen.swift`, `OnboardingOverlay.swift`, `OpenGlassesApp.swift`, `AccentColors.swift`

**Recommended next commit message:**

```
feat(imetaclaw): branding, Oi-wake agent identity, logo and app icon
```

---

## 10. Session History

| Date | Agent | Summary |
|------|-------|---------|
| Jun 24, 2026 | Manus | Keychain fixes, build/install, `AGENTS.md`, SecureField→TextField |
| Jun 24, 2026 | Manus | xAI provider, exhaustive switch fixes (`88e8d19`) |
| Jun 24, 2026 | Manus | Paste buttons, Claude OAuth, pt-BR xcstrings (`a30e20c`) |
| Jun 24–25, 2026 | Grok | Architecture analysis, Phase 1 AIOX plan, iMetaClaw branding, `Oi {bot}` wake, logo/icon, `AgentSettingsView`, this PROJECT-MAP |

---

## 11. Decisions Log

| # | Decision | Rationale | Status |
|---|----------|-----------|--------|
| D1 | Product name **iMetaClaw** (`imetaclaw.com`) | Meta glasses + OpenClaw; domain free | ✅ Approved |
| D2 | Wake phrase **`Oi {botName}`** not "Ei" or "Hey" | Brazilian natural + user bot name | ✅ Implemented (uncommitted) |
| D3 | Phase 1 = patch fork (Option C), Phase 2 = strip fork (Option B) | Ship faster, fork later | ✅ Approved |
| D4 | No Flutter/RN rewrite | Meta DAT SDK is iOS-native | ✅ Approved |
| D5 | Discrete recording = **audio-only** | Camera LED is hardware-enforced | ✅ Approved |
| D6 | AI primary path = **VPS OpenClaw**, APIs optional | Matches reseller model | ✅ Approved |
| D7 | Android = thin client Phase 3 | Shared protocol later | 📋 Planned |

---

## 12. Next Actions (Ordered)

| # | Action | Wave | Est. |
|---|--------|------|------|
| 1 | **Commit** uncommitted iMetaClaw work | W1 | 30 min |
| 2 | Rebuild & install on iPhone (⌘R) — verify icon + "Oi Maia" | W1 | 15 min |
| 3 | Implement `Config.simpleMode` + hide settings sections | W3 | 1 day |
| 4 | Gateway wizard page in onboarding + test connection | W2 | 1 day |
| 5 | `RecordingSettingsView` + LED disclaimer | W4 | 1 day |
| 6 | Fix `LiveTranslationService` for PT↔EN | W4 | 1–2 days |
| 7 | Complete pt-BR for onboarding + settings strings | W5 | 1–2 days |
| 8 | Connect Maia VPS (URL + token) and voice test | W2 | User + 1 hr |
| 9 | Pairing QR format + parser | W2 | 1 day |
| 10 | TestFlight archive pipeline | W5 | 2–3 days |

---

## 13. Traceability: Plan → Story → Status

| Planned (AIOX Epic) | Story ID | Status |
|---------------------|----------|--------|
| iMetaClaw branding | W1.* | 🚧 90% — uncommitted |
| Oi {bot} wake phrase | W1.6–W1.8 | 🚧 Done — uncommitted |
| Paste fix | W0.11 | ✅ `a30e20c` |
| Gateway onboarding wizard | W2.3–W2.4 | 📋 Planned |
| Maia VPS live | W2.6 | ❌ Blocked on credentials |
| simpleMode | W3.1–W3.3 | 📋 Planned |
| Recording settings | W4.2–W4.4 | 📋 Planned |
| Live PT↔EN translation | W4.6–W4.8 | 📋 Planned |
| pt-BR localization | W5.1–W5.2 | 🚧 Partial |
| TestFlight | W5.5 | ❌ Not started |
| Android client | W5.8 | 📋 Phase 3 |

---

## 14. Glossary

| Term | Meaning |
|------|---------|
| **iMetaClaw** | Product brand — Meta glasses + OpenClaw agent bridge |
| **Maia** | User's OpenClaw agent on Hostinger VPS (Telegram bot name) |
| **OpenClaw Gateway** | Server on port ~18789; app connects via `/health` + WebSocket `sessions.send` |
| **Gateway token** | Bearer auth for OpenClaw — **not** the same as Hostinger API token |
| **Oi {name}** | Wake phrase pattern — e.g. "Oi Maia" |
| **simpleMode** | Planned flag to hide upstream complexity |
| **Discrete recording** | Audio-only via glasses mic — no camera, no capture LED |
| **IDS** | Investigate existing → Decide REUSE/ADAPT/CREATE |
| **VPS bridge** | Planned server module that generates pairing QR for the app |

---

*Generated for AIOX Enterprise brownfield tracking. Update this file when waves complete or gaps close. Canonical companion: `AGENTS.md` (build/run instructions).*
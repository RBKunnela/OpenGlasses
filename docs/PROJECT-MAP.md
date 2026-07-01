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
  agent_vps: Hostinger KVM2 (srv753644) — OpenClaw agent "Maia" + Telegram bot
  hermes_vps: Hostinger KVM4 (aicontexteng.com) — AIOX/Hermes infra — NOT for glasses
  market: Brazil (pt-BR) + international (en)
  strategy: Phase 1 quick wins on iOS fork → Phase 2 iMetaClaw stripped fork → Phase 3 Android thin client
  map_version: "1.1.0"
  last_updated: "2026-06-25"
  map_author: Grok (sessions 4–5) + Manus (sessions 1–3)
  status_overall: IN_PROGRESS — Phase 1 ~50% complete; Maia E2E blocked on KVM2 /ws (Caddy)
```

---

## 1. Executive Summary

**iMetaClaw** is a simplified iOS companion for Ray-Ban Meta glasses that connects to an **OpenClaw agent on a VPS** (e.g. Maia on Hostinger). The phone is a voice + camera terminal; AI logic lives on the server.

The repo is a **brownfield fork** of upstream OpenGlasses (~400 Swift files, 85+ native tools). We are **not** rebuilding from scratch yet — Phase 1 adds branding, `Oi {bot}` wake phrase, agent settings, and fixes UX blockers while planning a stripped fork.

| Dimension | State |
|-----------|-------|
| **Build & install** | ✅ Builds on device (USB) |
| **Branding (iMetaClaw)** | 🚧 Done in working tree, not committed |
| **Maia / VPS connected** | ⚠️ **Blocked** — HTTP OK, WebSocket `/ws` returns 403 on KVM2 |
| **Sell-ready for Brazil** | ❌ Needs pt-BR completion, gateway wizard; `simpleMode` done (uncommitted) |
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
| `simpleMode` feature flag | **CREATE** | ✅ Implemented (uncommitted) — VPS terminal mode |
| Maia-only gateway guard | **CREATE** | ✅ `GatewayEndpoint.isHermesHost`, migration, block Hermes URLs |
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
Hostinger KVM2 — Maia ONLY (srv753644.hstgr.cloud)
  • Caddy :443 → must proxy /ws + /health → 127.0.0.1:18789 (OpenClaw)
  • Maia agent + Telegram bot (same OpenClaw session)
  • Port 18789 NOT public; iPhone uses HTTPS/WSS on 443 only

Hostinger KVM4 — Hermes (aicontexteng.com) — separate stack
  • AIOX / Hermes gateway / nginx — do NOT point iMetaClaw here
```

**Hard constraint:** Video/photo capture on Ray-Ban Meta **always triggers hardware capture LED** — cannot be disabled by third-party apps. **Discrete recording = audio-only only.**

### VPS inventory (corrected Jun 25, 2026)

| VPS | Hostname | IP | Plan | Role | Glasses app? |
|-----|----------|-----|------|------|--------------|
| **KVM2** | `srv753644.hstgr.cloud` | `46.202.188.144` | KVM 2 | **Maia** — OpenClaw + Telegram | ✅ **YES** |
| **KVM4** | `srv659320` / `aicontexteng.com` | `46.202.189.72` | KVM 4 | **Hermes** — AIOX infra | ❌ **NO** |

**DNS:** `aicontexteng.com` → KVM4. No `maia.*` subdomain yet. iPhone URL: `https://srv753644.hstgr.cloud`.

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
| W2.3 | Gateway wizard in **onboarding** | 🚧 Partial | Onboarding gateway page + Maia default URL (uncommitted) |
| W2.4 | Test connection button in onboarding | 🚧 Partial | Tap OpenClaw pill → diagnostic alert; `probeConnection()` exists |
| W2.5 | Pairing QR parser `imetaclaw://connect?...` | 📋 Planned | Full-stack / reseller flow |
| W2.6 | **Maia connected end-to-end** | ⚠️ **Blocked** | HTTP `/health` OK; `/ws` → 403 (Caddy → uvicorn, not :18789) |
| W2.7 | VPS `imetaclaw-bridge` install script | 📋 Planned | Server-side pairing code generation |
| W2.8 | Hostinger API auto-discovery | 🔍 Gap | Hostinger API token returns 403; ≠ gateway token |
| W2.9 | Hermes vs Maia VPS mapping documented | ✅ Done | This map + `AIOX-enterprise/.env` comments |
| W2.10 | Maia-only URL enforcement in app | 🚧 Uncommitted | `GatewayEndpoint`, `Config.migrateHermesGatewayToMaiaIfNeeded()` |
| W2.11 | KVM2 Caddy `/ws` → OpenClaw :18789 | ⚠️ **Blocked** | Claude Code in Hostinger terminal — in progress |
| W2.12 | `openclaw devices approve` (first pairing) | 📋 Planned | After `/ws` returns 101 |

### Wave 3 — Simplification (`simpleMode`)

| ID | Item | Status | Evidence / Notes |
|----|------|--------|------------------|
| W3.1 | `Config.simpleMode` flag | 🚧 Uncommitted | Defaults on; locks `vpsOnly` + `direct` mode |
| W3.2 | Tool whitelist (OpenClaw + camera + translate) | 🚧 Partial | `isOpenClawExclusive` skips local routing in `OpenGlassesApp` |
| W3.3 | Simplified Settings navigation | 🚧 Partial | Settings/onboarding simplified for terminal mode |
| W3.4 | Onboarding skips API key (gateway-only path) | 🚧 Partial | `simpleMode` forces gateway step; cloud path hidden |
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
| Maia VPS not connected | **P0** | Core value prop broken | Fix KVM2 Caddy `/ws` → :18789; Maia gateway token in app | VPS (Claude) + User |
| Caddy routes `/ws` to uvicorn not OpenClaw | **P0** | Orange pill + "Maia offline" | `handle /ws*` → `127.0.0.1:18789` before catch-all | Claude Code @ KVM2 |
| Hermes (KVM4) confused with Maia (KVM2) | **P0** | Wrong agent / wasted VPS work | App blocks `aicontexteng.com`; docs corrected | ✅ Mitigated in app |
| KVM2 SSH inaccessible from Mac | **P1** | Cannot fix VPS from Cursor | Reset root password in hPanel; or Hostinger terminal only | User |
| Hostinger API token 403 | **P2** | Cannot reset KVM2 password via API | hPanel manual reset | User |
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

**Gap verdict:** App-side terminal mode is ready (uncommitted). **P0 blocker is server-side:** KVM2 Caddy must expose OpenClaw WebSocket on 443. Reinstalling the iPhone app does not help until `/ws` returns HTTP 101.

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
| Gateway URL normalize + Hermes block | `OpenGlasses/Sources/Utils/GatewayEndpoint.swift` |
| Gateway settings | `OpenGlasses/Sources/App/Views/GatewaySettingsView.swift` |
| Voice routing / offline banner | `OpenGlasses/Sources/App/Views/VoiceTab.swift` (`VoiceRoutingBanner`, `StatusPillsRow`) |
| Connection pills (top bar) | `OpenGlasses/Sources/App/Views/ConnectionBanner.swift` |
| Env / VPS notes (gitignored) | `/Volumes/aiagents2TB/Dev/GITHUB/AIOX-enterprise/.env` |
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

**Uncommitted (iMetaClaw — Grok sessions 4–5, Jun 25):**

- **New:** `AppBranding.swift`, `AgentSettingsView.swift`, `GatewayEndpoint.swift`, `PasteableSecretField.swift`, `DeviceAICapability.swift`, `SpeechRecognitionLocale.swift`, `WearablesBootstrap.swift`, `OpenClawDeviceIdentity.swift`, logo/icon assets
- **Modified:** `Config.swift`, `OpenClawBridge.swift`, `OpenGlassesApp.swift`, `OnboardingView.swift`, `SettingsView.swift`, `GatewaySettingsView.swift`, `VoiceTab.swift`, `BottomControlBar.swift`, `ConnectionBanner.swift`, `WakeWordService.swift`, intents (`LiveAIModeIntents`, `ToggleGeminiLiveIntent`), tests (`ConfigTests`, `GatewayEndpointTests`)
- **Docs:** `docs/PROJECT-MAP.md` (this file)
- **External:** `AIOX-enterprise/.env` comments corrected (gitignored); KVM4 `/root/AIOX-enterprise/.env` warning note added via SSH

**Recommended next commit message:**

```
feat(imetaclaw): Maia-only gateway, simpleMode terminal, VPS diagnostics
```

---

## 10. Session History

| Date | Agent | Summary |
|------|-------|---------|
| Jun 24, 2026 | Manus | Keychain fixes, build/install, `AGENTS.md`, SecureField→TextField |
| Jun 24, 2026 | Manus | xAI provider, exhaustive switch fixes (`88e8d19`) |
| Jun 24, 2026 | Manus | Paste buttons, Claude OAuth, pt-BR xcstrings (`a30e20c`) |
| Jun 24–25, 2026 | Grok | Architecture analysis, Phase 1 AIOX plan, iMetaClaw branding, `Oi {bot}` wake, logo/icon, `AgentSettingsView`, this PROJECT-MAP |
| Jun 25, 2026 (session 4–5) | Grok + Claude Code | Maia/KVM2 vs Hermes/KVM4 correction; `simpleMode` + VPS-only routing; gateway guards; external probes; KVM2 `/ws` blocker identified |
| Jun 25, 2026 (ongoing) | Claude Code | Hostinger browser terminal on **KVM2** — Caddy `/ws` → OpenClaw :18789 (not yet verified externally) |

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
| D8 | **Maia = KVM2**, **Hermes = KVM4** | Earlier work targeted wrong VPS | ✅ Corrected |
| D9 | iMetaClaw must **never** use `aicontexteng.com` | Hermes OpenClaw ≠ Maia agent | ✅ App enforcement (uncommitted) |
| D10 | Telegram OK ≠ glasses OK | Telegram is server-side channel; app needs `/ws` on 443 | ✅ Documented |

---

## 12. Next Actions (Ordered)

| # | Action | Wave | Est. | Owner |
|---|--------|------|------|-------|
| 1 | **Fix KVM2 Caddy:** `/ws` + `/health` → `127.0.0.1:18789` (before uvicorn catch-all) | W2.11 | 30–60 min | Claude Code @ hPanel terminal |
| 2 | Verify external: `curl -sI -H 'Connection: Upgrade' -H 'Upgrade: websocket' 'https://srv753644.hstgr.cloud/ws?token=***'` → **101** | W2.6 | 5 min | Any agent |
| 3 | iPhone: URL `https://srv753644.hstgr.cloud` + Maia `gateway.auth.token`; tap OpenClaw pill → green | W2.6 | 15 min | User |
| 4 | KVM2: `openclaw devices list` → `openclaw devices approve --latest` | W2.12 | 10 min | Claude Code / User |
| 5 | **Commit** uncommitted iMetaClaw work | W1–W3 | 30 min | Dev |
| 6 | Rebuild & install on iPhone | W1 | 15 min | Dev |
| 7 | Complete pt-BR for onboarding + settings | W5 | 1–2 days | Dev |
| 8 | `RecordingSettingsView` + LED disclaimer | W4 | 1 day | Dev |
| 9 | Pairing QR format + parser | W2 | 1 day | Dev |
| 10 | TestFlight archive pipeline | W5 | 2–3 days | Dev |

---

## 13. Traceability: Plan → Story → Status

| Planned (AIOX Epic) | Story ID | Status |
|---------------------|----------|--------|
| iMetaClaw branding | W1.* | 🚧 90% — uncommitted |
| Oi {bot} wake phrase | W1.6–W1.8 | 🚧 Done — uncommitted |
| Paste fix | W0.11 | ✅ `a30e20c` |
| Gateway onboarding wizard | W2.3–W2.4 | 📋 Planned |
| Maia VPS live | W2.6 | ⚠️ Blocked on KVM2 `/ws` (Caddy) |
| KVM2 Caddy fix | W2.11 | ⚠️ Claude Code in progress |
| Hermes/Maia separation | W2.9–W2.10 | 🚧 Done — uncommitted |
| simpleMode | W3.1–W3.4 | 🚧 Done — uncommitted |
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
| **Maia** | User's OpenClaw agent on **Hostinger KVM2** (`srv753644`) — Telegram bot name |
| **Hermes** | Separate AIOX stack on **Hostinger KVM4** (`aicontexteng.com`) — not for glasses |
| **OpenClaw Gateway** | Listens on `127.0.0.1:18789`; public access via Caddy `/health` + `/ws` on 443 |
| **Gateway token** | `gateway.auth.token` from Maia's `~/.openclaw/openclaw.json` — not Telegram token, not Hermes token |
| **Orange OpenClaw pill** | HTTP `/health` OK, WebSocket not ready |
| **Red "Maia offline"** | `webSocketReady == false` — voice blocked in `vpsOnly` mode |
| **Oi {name}** | Wake phrase pattern — e.g. "Oi Maia" |
| **simpleMode** | Flag (default on) — VPS terminal; hides upstream complexity |
| **Discrete recording** | Audio-only via glasses mic — no camera, no capture LED |
| **IDS** | Investigate existing → Decide REUSE/ADAPT/CREATE |
| **VPS bridge** | Planned server module that generates pairing QR for the app |

---

## 15. Session 5 Handoff — Resume Here (Jun 25, 2026)

> **Stop point:** User closed session with Maia still offline on iPhone. Next agent should read this section first.

### 15.1 What we accomplished (app — Grok in Cursor)

| Area | Done (uncommitted) |
|------|---------------------|
| **VPS terminal mode** | `Config.simpleMode` locks `vpsOnly` + `direct`; blocks Gemini Live / local LLM routing |
| **Maia-only gateway** | Default URL `https://srv753644.hstgr.cloud`; blocks/migrates Hermes hosts (`aicontexteng.com`) |
| **Diagnostics** | Orange pill = "HTTP só — WS pendente"; red banner explains `/ws` blocked; tap OpenClaw pill for alert |
| **Onboarding** | Gateway step pre-fills Maia URL; PT copy warns KVM2 vs KVM4 |
| **Tests** | `GatewayEndpointTests` (Hermes detection), `ConfigTests` (migration, enabledGateways filter) |
| **Build** | `BUILD SUCCEEDED` on device target (Jun 25) |

### 15.2 What we accomplished (VPS — mixed; mostly wrong host first)

| Host | What happened |
|------|----------------|
| **KVM4 (Hermes)** | SSH via `~/.ssh/id_ed25519` works. Installed/restarted OpenClaw, nginx `/ws` on `aicontexteng.com` — **works for WebSocket but wrong agent**. Left warning in `/root/AIOX-enterprise/.env`. |
| **KVM2 (Maia)** | SSH from Mac **fails** (password + key). Work delegated to **Claude Code in Hostinger browser terminal** (user confirmed still in progress). |

### 15.3 The blocker (P0 — unchanged at session end)

External probes (last: **2026-06-25 ~14:57 UTC**):

```
https://srv753644.hstgr.cloud/health  → 200  (Server: uvicorn — Maia status JSON)
https://srv753644.hstgr.cloud/ws      → 401/403 (Server: uvicorn — NOT OpenClaw)
http://46.202.188.144:18789           → port closed from internet
wss://aicontexteng.com/ws             → OK connect.challenge (Hermes — wrong for glasses)
```

**Root cause:** Caddy on KVM2 sends `/ws` to the **Maia Python API (uvicorn)**, not to **OpenClaw on `127.0.0.1:18789`**. The iPhone app cannot work until `/ws` returns **HTTP 101 Switching Protocols**.

**UI mapping:**

| UI | Meaning |
|----|---------|
| Orange OpenClaw dot | `connectionState == .connected` but `webSocketReady == false` |
| Red triangle "Maia offline" | `vpsOnly` mode + no WebSocket — voice disabled by design |

Reinstalling the app **does not** fix this.

### 15.4 Claude Code on Hostinger terminal — intended fix

**Must run on `srv753644` (KVM2), not `srv659320` (KVM4).**

```bash
hostname   # expect srv753644
curl -s http://127.0.0.1:18789/health
cat /etc/caddy/Caddyfile

# /ws and /health for OpenClaw MUST appear BEFORE catch-all to uvicorn:
# handle /ws* { reverse_proxy 127.0.0.1:18789 }
# handle /health { reverse_proxy 127.0.0.1:18789 }

caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy

TOKEN=$(python3 -c "import json; print(json.load(open('/root/.openclaw/openclaw.json'))['gateway']['auth']['token'])")
curl -sI -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  "https://srv753644.hstgr.cloud/ws?token=$TOKEN" | head -5
# SUCCESS = HTTP/1.1 101 Switching Protocols
```

After 101: `openclaw devices approve --latest` on KVM2.

### 15.5 iPhone config (after VPS fix)

| Field | Value |
|-------|-------|
| Gateway URL | `https://srv753644.hstgr.cloud` |
| Token | Maia KVM2 `gateway.auth.token` (not Hermes, not Telegram) |

### 15.6 Access credentials (where to look — do not commit)

| Secret | Location |
|--------|----------|
| Hostinger API token | `~/Downloads/env`, `AIOX-enterprise/.env` |
| KVM2 root password (may be stale) | `HOSTINGER_VPS_KVM2_PASSWORD` in env |
| SSH key to KVM4 only | `~/.ssh/id_ed25519` |
| Hermes gateway token (wrong for Maia) | KVM4 vault / `.env` — do not use on iPhone |

### 15.7 First actions for next session

1. Re-run external probe on `wss://srv753644.hstgr.cloud/ws` — if still 403, Claude's Caddy fix not done.
2. If 101: user tests iPhone (no reinstall needed); expect green pill + voice via Maia.
3. Commit uncommitted iMetaClaw work once E2E confirmed.
4. Optional: DNS `maia.aicontexteng.com` → `46.202.188.144`; reset KVM2 SSH password in hPanel for Mac access.

### 15.8 Collaboration model

| Agent | Role |
|-------|------|
| **Claude Code** @ Hostinger terminal | KVM2 infra: Caddy, OpenClaw, device pairing |
| **Cursor / Grok** | iOS app, probes from Mac, `PROJECT-MAP.md`, builds |

---

*Generated for AIOX Enterprise brownfield tracking. Update this file when waves complete or gaps close. Canonical companion: `AGENTS.md` (build/run instructions).*
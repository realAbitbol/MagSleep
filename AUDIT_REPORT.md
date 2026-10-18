# MagSleep — Full-Codebase Audit Report

**Repository:** `/Users/nicolascampy/VSCode projects/MagSleep` (branch `master`, commit `cc6994a`; working tree carries an in-progress Periphery→Lethen rename)
**Audit date:** 2026-10-18
**Scope:** every tracked file — `Sources/` (21 Swift files), `Tests/` (3 files), `scripts/` (12 files), `packaging/` (3 files), `.github/workflows/` (2), and all root config/docs.
**Nature:** review pass only. No repository file was modified. All proposed changes are unified diffs inside this report.

---

## 1. Verdict

**Shippable — with caveats.** This is a small, unusually disciplined codebase for its scope: the pure core is well-factored and well-tested, the privileged path is hardened far beyond the usual hobby-daemon bar, and the release pipeline has real supply-chain thinking in it. I found **no Critical and no High defects**. The four Medium findings are all *hygiene/consistency* problems (CI secret scoping, an unsignalled update state, a release-flow blocker, and an untested security surface), not correctness or security breaks. Nothing here would stop me from installing the current build on my own machine.

The caveats worth acting on, in order: (1) the two release secrets are exposed to every step of the release job, including steps that execute repo and third-party build code; (2) declining the "outdated helper" prompt leaves the app with no visible signal even though the code comments claim otherwise; (3) the `master` tree currently cannot produce a release (untracked docs + dirty tracked files trip `release.sh`'s guard); (4) the daemon's socket server — the main IPC and authorization surface — has zero tests while two latent bugs sit one layer beneath it.

### Scoring table

| Axis | Grade | One-line justification |
|---|---|---|
| Security | **A−** | Fail-closed peer auth, cdhash-pinned install, secrets never in argv for Sparkle, attestation — one real CI scoping gap and one argv leak in the VT helper. |
| Correctness | **A−** | Pure decision logic is correct and matrix-tested; three small behavioural gaps found (unsignalled upgrade, unpersisted disable, fat64 parse). |
| Performance | **A** | Everything measured is negligible; the 3s re-assert is deduped (−28,800 writes/day); one sub-second main-thread probe at launch. |
| Robustness | **A−** | Bounded subprocesses, atomic config writes, self-healing socket, graceful degradation everywhere; one missing wake cross-check. |
| Concurrency | **A** | No races found: all daemon state is main-run-loop-confined and documented as such; dispatch handlers are serialised on `.main`. |
| Architecture | **B+** | Layering is sound and the shared-core split is genuinely drift-proof; two god-objects in the app (`StatusItemController`, `HelperManager`). |
| API / contract | **A−** | Wire vocabulary single-sourced; only an ambiguity about absent-vs-null keys, which the client already tolerates. |
| Observability | **B** | The daemon logs well (os.log, throttled, public peer uids); the app has essentially no logging, so user failures aren't reconstructable. |
| Testing | **B** | 95/95 pass in 1.35 s and cover the pure core thoroughly — but the socket server, the daemon, `StatusItemController`, and `HelperManager` are untested. |
| Dependencies | **A** | One dependency (Sparkle 2.9.5), pinned in `Package.resolved`, no CVEs, no drift. |
| Build / CI / deploy | **B+** | CI-only release with Sigstore attestation is genuinely good; mutable action tags, a job-level-secret scope, a bot-email typo, and non-reproducible "reproducible" bytes. |
| Config / flags | **A** | No sprawl; optional config key is forward/backward compatible; no secret in config. |
| Docs / knowledge | **B** | ARCHITECTURE/STRUCTURE/AGENTS are excellent and mostly accurate; the README menu table has drifted twice. |
| DX | **A−** | One-command build/test/lint/release, error-annotated scripts, tracked git hooks; the only friction is the untracked-doc release block. |
| Compatibility / portability | **A−** | Deliberate arm64-only, macOS 14+; two deprecated activation APIs; private API used with a documented fallback. |
| Accessibility / i18n | **B** | Onboarding cards do proper AX radio-button work; English-only hard-coded strings; one toggle not disambiguated by state. |
| Compliance / licensing | **A** | MIT, single permissive dependency, no personal data processed. |
| Data integrity | **A** | Atomic writes, corrupt-config healing, additive schema evolution, no migrations needed. |

---

## 2. Methodology — what I verified

### Commands run (exact results)

| Command | Result |
|---|---|
| `swift test` | **95 tests, 0 failures (0 unexpected), 1.349 s** — build 7.85 s |
| `swiftlint lint --strict` | **0 violations, 0 serious in 27 files** (SwiftLint 0.65.1) |
| `lethen scan --strict` | **"No unused code detected."** exit 0 (Lethen 2026.10.1) |
| `codesign --verify --deep --strict dist/MagSleep.app` | exit 0 — *"valid on disk / satisfies its Designated Requirement"* |
| `python3` unix-socket probe (unknown command) | `{"id":"audit-probe","ok":false,"error":"unknown command"}` — one newline-terminated line, config byte-identical before/after |
| `git log --since="6 months ago"` | 75 commits touched since 2026-04-18 |
| `git ls-files --others --exclude-standard` | `ARCHITECTURE.md`, `STRUCTURE.md` |
| Reproductions | fat64 Mach-O probe (compiled against the real `MagSleepCore`); bash `for`-loop return-status demo; argv-visibility demo |

### Reproductions (deterministic)

1. **fat64 parse defect.** Compiled a probe against the real module (`.build/out/Products/Debug/libMagSleepCore.a`) that wraps an identical thin arm64 Mach-O in a `FAT_MAGIC` (32-bit) and a `FAT_MAGIC_64` container:

   ```
   thin  (MH_MAGIC_64)   : 9a12d05b5212e57103b7e32a189491b4de1a9c35a481a59bdb36649c259706ec
   fat32 (FAT_MAGIC)     : 9a12d05b5212e57103b7e32a189491b4de1a9c35a481a59bdb36649c259706ec
   fat64 (FAT_MAGIC_64)  : nil
   ```
   A valid fat64 arm64 image yields **nil**, not the thin hash. (Finding 5.)

2. **Socket protocol + auth, live.** The installed daemon is running on this machine (`launchctl print system/com.magsleep.helper` → `state = running`). Sent one unknown command over `/var/run/magsleep.sock`; got a well-formed ack with `ok:false`, and `config.plist` was byte-identical afterwards. This exercises the real accept → `getpeereid` → parse → dispatch → encode path end to end. It also confirmed the wire form omits nil `config`/`error` keys. (No mutating command was sent.)

3. **Bash return-status.** Verified that the `for … do … done` shape used by `wait_for_job_gone` returns 0 when the loop completes without an early `return`, so the function can never signal failure.

### Environment / platform caveats

- Audited on **macOS 26 / Apple Silicon (arm64e)** with Swift 6.x toolchain, SwiftLint 0.65.1, Lethen 2026.10.1. `.build` uses the new SwiftPM `out/{Intermediates,Products}` layout.
- The local `dist/MagSleep.app` is a **stale** artifact (v1.3.2, built 2026-08-07, `builtBy: local`); the source is at v1.3.7. I inspected the bundle for structure/signing facts only and did **not** treat it as the shipped build.
- The machine's **installed** helper is revision `555c313` (v1.3.5-era) with `nightScheduleEnabled=false` — i.e. it genuinely differs from the bundled `b63643d`, so the update-detection path would legitimately trigger. I could not exercise the content-hash comparison end-to-end without performing a privileged install, which the audit forbids.
- I rarely `ps`-visible argv on a multi-user box for the VT-key finding; that is a general POSIX fact demonstrated with a benign value.

### Refuter tally (adversarial verification)

No finding reached **High**, so the mandatory refutation gate was not triggered. I nonetheless dispatched a fresh-context subagent with explicitly *no* prior conclusions to refute the four Medium findings using only the repo and fresh tool results.

| Claim | Verdict |
|---|---|
| 1. Declined helper update is never signalled | **SURVIVED** — no `needsUpgrade` branch in `statusImage`/`statusTitle`/`updateMenuStates`; `checkUpgrade` runs once at startup; the About dialog is the only `helperIsCurrent` consumer and is user-initiated |
| 2. `arm64Slice` mis-parses `FAT_MAGIC_64` | **SURVIVED** — SDK header confirms `fat_arch_64` = 32 bytes (64-bit offset@+8, size@+16); the probe confirms nil; refuter argues real-world impact sits at the *Low* end since the shipped helper is thin arm64 (severity recorded as Low, latent) |
| 3. `make release` blocked today | **SURVIVED** — guard confirmed to count untracked files; refuter added the nuance that the dirty tracked files independently trip the same guard |
| 4. Job-level release secrets | **SURVIVED** — every step inherits them, including `swift test`/`swift build`; the EdDSA key is the app's permanent update-trust anchor |

**Tally: 0 refuted · 0 downgraded at the claim level (1 severity note) · 4 survived.**

### Files read

**In full (every line):** all 21 files in `Sources/`; all 3 files in `Tests/`; all 12 files in `scripts/`; all 3 files in `packaging/`; both workflows; `Package.swift`, `Package.resolved`, `Makefile`, `.swiftlint.yml`, `.gitignore`, `README.md`, `CHANGELOG.md`, `SECURITY.md`, `LICENSE`, `AGENTS.md`, `ARCHITECTURE.md`, `STRUCTURE.md`, `appcast/appcast.xml`, `.github/FUNDING.yml`.
**Sampled/inspected:** the built `dist/MagSleep.app` bundle (signing, Resources, provenance, xattrs), the live installed helper + socket + config on this machine.
**Not read:** `.build/` and `dist/` binaries in full (inspection only), `.DS_Store`, `.cortexkit/` (session state — off-limits by policy), `Sparkle.framework` internals (third-party).

### Scope decisions

The repo is ~6.4 k lines including tests and docs, so **no deprioritisation was needed** — the whole tree was read. Deepest attention went to the trust boundaries: the unix-socket protocol, the privileged installer, the child-process runner, the Mach-O parser used for update detection, and the release workflow. Axes 16 (i18n) and 18 (data migration) are largely out of scope and are marked as such rather than padded.

---

## 3. Calibration Baseline

The standards this audit *actually* judged against — extracted from the project's own rules, not from generic best practice.

1. **Language/runtime:** Swift, `swift-tools-version:5.10`, `platforms: [.macOS("14.0")]`, **arm64 only** (Intel explicitly unsupported and refused at launch). No support window for older macOS.
2. **Shape (invariant):** two processes — an unprivileged AppKit menu-bar app and a **root LaunchDaemon** — sharing one pure library (`MagSleepCore`) that must import only Foundation/IOKit/CryptoKit/Darwin (no AppKit, no Sparkle).
3. **Wire contract (invariant):** one request per unix-socket connection, one newline-terminated JSON line each way (`SocketRequest`/`SocketResponse`); the command vocabulary is defined **once** as `RequestCommand` constants and never as string literals at call sites.
4. **Security posture (stated):** fail closed — reject any peer whose `getpeereid` uid is neither root nor the current console user; verify the app bundle signature **and** a build-time cdhash pin before any privileged write; strip `com.apple.quarantine`/`com.apple.provenance`; re-sign the daemon ad-hoc at its final path.
5. **Secrets policy (stated, and stricter than typical):** the Sparkle EdDSA key is piped via `--ed-key-file -` "so it never lands on disk or in argv"; `SPARKLE_EDDSA_KEY` is read from the env "never from argv — argv would leak into the process list". *This is the project's own bar and the yardstick for finding 6.*
6. **Release policy (stated):** releases are **CI-only**; nothing a maintainer's machine could tamper with reaches users; every published DMG is built from scratch on a runner, VirusTotal-scanned, EdDSA-appcast-signed, Sigstore-attested, and the feed is committed only *after* the release is live.
7. **Quality gates (stated and real):** `swiftlint lint --strict`, `lethen scan --strict`, `swift test`, and a `-warnings-as-errors` release build — run by `make lint`, by the tracked pre-commit hook, and (tests) by CI.
8. **Dead code policy (explicit deviation):** `// periphery:ignore` comments are the sanctioned suppression mechanism for C-interop struct fields and retained-for-lifetime properties; the helper entry point **must** stay `@main` so the analyzer can trace it. (Working tree is mid-migration from Periphery to Lethen; the directives are intentionally unchanged.)
9. **Documented non-goals:** not notarized (no paid Apple Developer membership) — Gatekeeper friction is an accepted, documented cost; Shortcuts/App Intents removed because SwiftPM cannot emit the metadata; Notification Blink removed because TCC pins AX grants to a signing identity that changes every ad-hoc build.
10. **Reliability posture (stated, must not be "fixed"):** `KeepAlive { SuccessfulExit: false }` + SIGTERM handler that restores the LED to macOS control and exits non-zero; the brief LED return before launchd revives the daemon is an intentional, observable behaviour.
11. **Dependency policy:** minimal — one direct dependency (Sparkle), pinned via `Package.resolved`; no vendoring.
12. **Explicitly accepted risks:** undocumented/private MagSafe `ACLC` SMC key may break on any macOS/firmware update; the `corebrightnessdiag` sun-schedule tool is undocumented and may move or vanish (hence the 20:00–07:00 fallback); 0666 socket with uid-based authorization; ad-hoc signing.

---

## 4. Gravity Wells

**Refactor Priority Score = lines_of_code × commits_in_last_6_months** (75 commits in the window; 2026-04-18 → 2026-10-18). Current files only — churn from files deleted in the window (`NotificationBlink.swift`, `AccessibilityNode.swift`, `UpdateChecker.swift`, `AppIntents.swift`, `Version.swift`, `main.swift`, `set-mode.sh`, `disable-helper.sh`, `build-cask.sh`, `cert-diagnostic.yml`) is excluded from the ranking but explains why the top-of-history has many deleted paths.

| Rank | File | Lines | Commits (6 mo) | Priority | Tests? | Headline issue |
|---|---|---|---|---|---|---|
| 1 | `Sources/MagSleep/StatusItemController.swift` | 756 | 23 | **17,388** | ❌ none | God-controller; contains the unsignalled-upgrade defect (F2) |
| 2 | `Sources/MagSleep/HelperManager.swift` | 556 | 12 | **6,672** | ⚠️ only via `HelperVersioning` | Unpersisted disable (F7); blocking main-thread probe (F13) |
| 3 | `Sources/MagSleepHelper/MagSleepHelperMain.swift` | 625 | 5 | **3,125** | ❌ none | Dropped wake event can leave the LED off (F8) |
| 4 | `Sources/MagSleep/OnboardingWindowController.swift` | 490 | 4 | **1,960** | ❌ none | Mandatory install flow entirely untested |
| 5 | `Tests/.../MagSleepCoreEdgeCaseTests.swift` | 424 | 4 | 1,696 | ✅ is tests | — (test file) |
| 6 | `scripts/install-helper.sh` | 147 | 10 | **1,470** | ❌ none | Highest-churn script; self-referential pin (F10), `wait_for_job_gone` (F9) |
| 7 | `Sources/MagSleepCore/SMC.swift` | 279 | 5 | 1,395 | ⚠️ partial | Struct layout + `fourCC` tested; all IOKit paths untested |
| 8 | `Tests/.../MagSleepCoreArchitectureTests.swift` | 221 | 6 | 1,326 | ✅ is tests | — (test file) |
| 9 | `Tests/.../MagSleepCoreTests.swift` | 351 | 3 | 1,053 | ✅ is tests | — (test file) |
| 10 | `Sources/MagSleepHelper/SocketServer.swift` | 232 | 3 | **696** | ❌ none | The IPC + authorization surface has **zero** tests (F4) |
| 11 | `.github/workflows/release.yml` | 256 | 3 | 768 | ❌ none | Job-level secrets (F1), mutable action tags (F11), email typo (F12) |
| 12 | `scripts/build-app.sh` | 122 | 7 | 854 | ❌ none | Timestamped BUILD_NUMBER ⇒ non-reproducible bytes (F19) |
| 13 | `scripts/release.sh` | 91 | 9 | 819 | ❌ none | Clean-tree guard vs untracked docs (F3) |
| 14 | `Sources/MagSleep/MagSleepApp.swift` | 85 | 5 | 425 | ❌ none | Deprecated activation API (F15) |
| 15 | `Sources/MagSleepCore/DaemonState.swift` | 84 | 5 | 420 | ✅ yes | Pure logic, well covered |
| 16 | `Sources/MagSleepCore/Constants.swift` | 68 | 5 | 340 | ✅ yes | — |
| 17 | `scripts/make-icon.swift` | 107 | 3 | 321 | ❌ none | Cosmetic asset generator |
| 18 | `Sources/MagSleepCore/MachOContentHash.swift` | 125 | 2 | 250 | ⚠️ thin path only | fat64 defect (F5) lives in the untested branch |
| 19 | `Sources/MagSleepCore/BoundedProcess.swift` | 115 | 2 | 230 | ✅ yes | Unjoined drains on the error path (F14) |
| 20 | `Sources/MagSleep/HelperConnection.swift` | 136 | 2 | 272 | ❌ none | Socket client; exercised only through live use |

**Highest-risk by default (gravity well × no tests):** `StatusItemController.swift`, `HelperManager.swift`, `MagSleepHelperMain.swift`, `OnboardingWindowController.swift`, `SocketServer.swift`, `scripts/install-helper.sh`. Note that `SocketServer.swift` is *not* a thin shell — it owns the authorization boundary — so its absence of tests is the sharpest test-coverage gap in the project (F4).

**Mining the history.** The last six months show a clear pattern: nearly every bug-fix release (1.1.1, 1.2.1, 1.2.9, 1.2.10, 1.3.2, 1.3.3, 1.3.4, 1.3.5) is a *helper lifecycle / install / update-detection* fix. That is exactly where the churn (rank 2, 6, 11, 12, 13) and the missing tests coincide. There are no `TODO`/`FIXME`/`HACK` markers in the source at all — the debt is captured in changelog prose instead, which is why it is easy to miss. Two regressions were self-inflicted by over-eager hardening and reverted within the window (the 1.3.2 cdhash comparison, removed in 1.3.3) — a signal that the install/update path is the part of this system that most needs executable tests rather than reasoning.

---

## 5. Findings table

Ordered by severity × confidence × gravity. `Sev` = Critical/High/Medium/Low/Info. `Conf` = confidence. **This table is the historical audit record; per-ID outcomes from the remediation pass are in §13.**

| ID | Sev | Conf | Axis | Location | One-liner |
|---|---|---|---|---|---|
| F1 | Medium | High | Security | `.github/workflows/release.yml:34-39` | Release-signing and VT secrets sit at **job** `env`, so every step — incl. `swift test`/`swift build` — can read them |
| F2 | Medium | High | Correctness / UX | `Sources/MagSleep/StatusItemController.swift:238-257, 684-706` | Declining the "outdated helper" prompt leaves **no** signal; the in-code comment claims the icon signals it |
| F3 | Medium | High | Build / CI | `scripts/release.sh:36-41` + working tree | `make release` is blocked today (untracked `ARCHITECTURE.md`/`STRUCTURE.md` *and* dirty tracked files) |
| F4 | Medium | High | Testing | `Sources/MagSleepHelper/SocketServer.swift` (whole file) | The IPC + authorization surface has no tests at all |
| F5 | Low | High | Correctness | `Sources/MagSleepCore/MachOContentHash.swift:88-112` | `FAT_MAGIC_64` mis-parsed → nil hash for any universal build (reproduced) |
| F6 | Low | High | Security | `scripts/virustotal-scan.sh:52-55` | VT API key passed in `curl` argv (visible via `ps`) — violates the project's own "never in argv" policy |
| F7 | Low | High | Correctness | `Sources/MagSleep/HelperManager.swift:398-412` | `disable()` while the daemon is down reports success but is never persisted ⇒ reverts on daemon restart |
| F8 | Low | High | Robustness | `Sources/MagSleepHelper/MagSleepHelperMain.swift:357-365, 572-575` | A dropped `systemHasPoweredOn` leaves Sleep-Mode's LED off indefinitely (no power-state cross-check) |
| F9 | Low | High | Correctness | `scripts/install-helper.sh:75-86` | `wait_for_job_gone` can never signal failure (bash `for` returns 0) ⇒ silent 5 s cap |
| F10 | Low | Medium | Security | `scripts/install-helper.sh:41-65`; `scripts/build-app.sh:105-114` | The integrity pin lives inside the bundle it validates ⇒ can't stop a wholesale bundle swap |
| F11 | Low | Medium | Supply chain | `.github/workflows/release.yml:42,135`; `codeql.yml:30,32` | Actions pinned to mutable major tags, not commit SHAs |
| F12 | Low | High | Correctness | `.github/workflows/release.yml:100` | Bot author email typo `magleep[bot]` (missing `s`) in the feed-repair path |
| F13 | Low | Medium | Performance | `HelperManager.swift:74-93`; `AppleScriptCommands.swift:97-100` | Blocking socket probe on the main thread at launch and on the first `get led status` |
| F14 | Low | Medium | Robustness | `Sources/MagSleepCore/BoundedProcess.swift:48-54` | Early-return path leaves the two pipe-drain tasks unjoined |
| F15 | Low | High | Compatibility | `StatusItemController.swift:105`; `MagSleepApp.swift:51` | Two activation calls deprecated *in the project's own minimum OS (14.0)* |
| F16 | Low | Medium | UX | `StatusItemController.swift:367-375, 453-467` | "Night Schedule" isn't disabled when the helper is down or Disabled — it alerts instead |
| F17 | Low | Medium | Docs | `README.md:119-130`; `AGENTS.md` (menu summary) | Menu reference omits Night Schedule; README shows an ellipsis on "Report a Problem…" the code doesn't have |
| F18 | Info | High | Docs | `Package.swift:1` vs `README.md:14` | "Swift 6" badge vs `swift-tools-version:5.10` |
| F19 | Info | Medium | Build | `scripts/build-app.sh:10,70-79`; `release.yml:30-33` | Timestamped build number ⇒ release bytes are **not** reproducible; the comment overstates it |
| F20 | Info | High | Robustness | `scripts/apply-vt-proof.py:20` | Unvalidated `sys.argv[1:5]` ⇒ traceback on a malformed invocation |
| F21 | Info | High | Observability | `Sources/MagSleep/*` | The app has essentially no logging (one `NSLog`), so user failures aren't reconstructable |
| F22 | Info | Medium | Concurrency | `SocketServer.swift:81, 154-158` | 32-client cap + backlog 8 ⇒ a same-user process can transiently deny the app's requests |

---

## 6. Detailed findings

### F1 — Release secrets are exposed to every step of the release job (Medium, Security, Confidence High)

**What happens.** `.github/workflows/release.yml:34-39` declares `VIRUSTOTAL_API_KEY`, `SPARKLE_EDDSA_KEY` and `GH_TOKEN` as *job-level* `env:`. Job-level environment is inherited by every step, including:

```yaml
      - name: Run tests
        run: swift test                       # :114-115
      - name: Build app bundle
        run: scripts/build-app.sh "…"         # :117-118
```

`swift test` / `swift build` compile and run repository code, SwiftPM manifests, and any build tooling pulled in transitively. Every one of those processes can read both secrets from the environment.

**Why it is wrong relative to the baseline.** Baseline #5 makes the project's own bar explicit: the EdDSA key is handled via `--ed-key-file -` "so it never lands on disk or in argv", and `verify-sparkle-key.swift` says it reads the env "never from argv — argv would leak into the process list". The project reasons carefully about *argv* exposure and then leaves the same key world-readable to every child process in the job. That is an internal inconsistency, not merely a generic best-practice nit.

**Impact.** `SPARKLE_EDDSA_KEY` is the app's **permanent update-trust anchor** — `verify-sparkle-key.swift:31-42` proves it derives the `SUPublicEDKey` embedded in every shipped client. Exfiltration lets an attacker sign an update that *every* installed MagSleep accepts, and the only remedy is to ship a new public key in a new release. The realistic vector is not a malicious tag-pusher (they already control the workflow) but a compromised dependency or build tool reachable from `swift test`/`swift build`.

**Smallest correct fix.** Scope each secret to the single step that needs it, and drop `GH_TOKEN` from job scope (GitHub already provides `github.token` to `gh` when passed explicitly, which the publish steps can do).

```diff
     env:
-      VIRUSTOTAL_API_KEY: ${{ secrets.VIRUSTOTAL_API_KEY }}
-      SPARKLE_EDDSA_KEY: ${{ secrets.SPARKLE_EDDSA_KEY }}
-      # gh does not auto-read GITHUB_TOKEN in Actions — without GH_TOKEN the
-      # publish step fails with exit 4.
-      GH_TOKEN: ${{ github.token }}
     steps:
@@
       - name: VirusTotal scan
         id: vt
+        env:
+          VIRUSTOTAL_API_KEY: ${{ secrets.VIRUSTOTAL_API_KEY }}
         run: |
@@
       - name: Sign Sparkle appcast
+        env:
+          SPARKLE_EDDSA_KEY: ${{ secrets.SPARKLE_EDDSA_KEY }}
         run: |
@@
       - name: Publish GitHub Release
+        env:
+          GH_TOKEN: ${{ github.token }}
         run: |
@@
       - name: Commit appcast + VirusTotal proof to master
+        env:
+          GH_TOKEN: ${{ github.token }}
         run: |
```

**Acceptance test.** Add a throwaway step `run: test -z "${SPARKLE_EDDSA_KEY:-}" && echo "ok: not in scope"` immediately after `Run tests`; it must print `ok`. Then confirm the `Sign Sparkle appcast` step still signs (the workflow already asserts an `sparkle:edSignature` on the new entry).

**What would raise confidence further.** Running a deliberately malicious SwiftPM build plugin to prove reachability — the static scoping evidence is conclusive as-is.

---

### F2 — A declined helper update is silently never signalled (Medium, Correctness/UX, Confidence High)

**What happens.** At startup the app chains `checkInstall → checkUpgrade → launch-at-login → recovery`. `checkUpgrade` (`StatusItemController.swift:109-115`) shows "Outdated Helper Detected" exactly once per launch. If the user picks **Later**, the completion runs `completion(false)` with this comment (`:702-703`):

> *"Declining no longer quits the app; the status icon keeps signaling that the helper needs an update."*

But `statusImage()` (`:238-257`) branches only on `isInstalling || isWaitingForDaemon`, `!isInstalled`, `!isLoaded`, `!isEnabled`, and otherwise the mode — there is **no `needsUpgrade` branch**, and neither `statusTitle` (`HelperManager.swift:126-146`) nor `updateMenuStates()` (`:609-636`) reacts to it. `needsUpgrade` is referenced in exactly one place in the app: the `checkUpgrade` guard. So after "Later" the icon shows the ordinary `moon.zzz` + "Sleep Mode Active", and nothing prompts again until the next launch.

**Impact.** The helper silently stays on an old revision. Because the helper owns the LED and the install/update lifecycle, "old helper + new app" is precisely the state that produced the 1.3.3/1.3.4 regressions; the user has no way to see it, and the only remaining surface is About → "Helper up to date: No" (which requires them to go looking).

**Smallest correct fix.** Make the icon honest about the state the comment describes (this is user-facing polish, not debug UI, so it is within the project's rules):

```diff
     private func statusImage() -> NSImage? {
         let symbolName: String
         if helper.isInstalling || helper.isWaitingForDaemon {
             symbolName = "hourglass"
         } else if !helper.isInstalled {
             symbolName = "exclamationmark.triangle"
         } else if !helper.isLoaded {
             symbolName = "exclamationmark.triangle"
+        } else if helper.needsUpgrade {
+            symbolName = "arrow.down.circle"
         } else if !helper.isEnabled {
             symbolName = "circle.slash"
         } else {
```

and mirror it in `statusTitle`:

```diff
         if !isLoaded {
             return connectionFailed ? "Can't connect to helper" : "Helper not running"
         }
+        if needsUpgrade {
+            return "Helper update available"
+        }
         if !isEnabled {
             return "Disabled"
         }
```

**Acceptance test.** With an installed helper whose content hash differs from the bundled one, launch and choose **Later**: the icon must change and the tooltip must read "Helper update available". `updateMenuStates()` is already called after the startup chain, so no extra plumbing is needed.

---

### F3 — `master` cannot currently produce a release (Medium, Build/CI, Confidence High)

**What happens.** `scripts/release.sh:36-41` refuses to run unless the tree is clean, counting *untracked* files:

```bash
if ! git diff --quiet || ! git diff --cached --quiet \
    || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "error: working tree has uncommitted changes; commit or stash first" >&2
```

On this tree:

```
$ git ls-files --others --exclude-standard
ARCHITECTURE.md
STRUCTURE.md
```

Both are new root docs (referenced by nothing in-tree, and `.gitignore` does not cover them — it ignores `docs/`, not root Markdown). The refuter confirmed the guard trips, and added an important nuance: the seven *modified tracked* files (`AGENTS.md`, `Makefile`, `README.md`, `SMC.swift`, `SocketProtocol.swift`, `MagSleepHelperMain.swift`, `scripts/git-hooks/pre-commit` — the in-progress Periphery→Lethen rename) independently trip the same guard, so committing the two docs alone would not unblock a release.

**Impact.** The documented release path (`make release VERSION=x.y.z`) fails at step 1. Anyone following the README's release instructions hits a confusing error. This is a repo-state matter, not a code defect — but it is the kind of thing that turns into a lost file when someone reaches for `git clean -fdx`.

**Smallest correct fix.** Commit (or delete) `ARCHITECTURE.md`/`STRUCTURE.md` and finish the Lethen rename as one commit, e.g.:

```
git add ARCHITECTURE.md STRUCTURE.md \
        AGENTS.md Makefile README.md \
        Sources/MagSleepCore/SMC.swift Sources/MagSleepCore/SocketProtocol.swift \
        Sources/MagSleepHelper/MagSleepHelperMain.swift scripts/git-hooks/pre-commit
git commit -m "Track architecture docs; migrate dead-code scan Periphery → Lethen"
```

**Acceptance test.** `git status --porcelain` is empty and `scripts/release.sh 0.0.0` reaches the tag-existence check (its own version validation) rather than the clean-tree guard.

**Note on this report.** Adding `AUDIT_REPORT.md` at the repo root creates one more untracked file and will likewise block `make release` until it is committed or removed — worth doing deliberately.

---

### F4 — The socket server (the IPC *and* authorization surface) is untested (Medium, Testing, Confidence High)

**What happens.** `Tests/MagSleepCoreTests/` covers only `MagSleepCore`. `Sources/MagSleepHelper/SocketServer.swift` (232 lines) implements the accept loop, the 4 KiB request cap, the 32-client cap, the 10 s idle sweep, the `getpeereid` read, the self-healing rebind, and the stop/start fd-state machine. None of it is executed by any test. The daemon's peer-authorization decision is exercised only in the abstract via `SocketCommandHandler` (which takes `isAuthorized` as a *parameter*), so the code that actually computes `isAuthorized` (`PowerDaemon.isAllowedPeer`, `MagSleepHelperMain.swift:239-247`) has no coverage either.

**Why the "thin shell" defence doesn't apply here.** `STRUCTURE.md` justifies the app/daemon having no tests because they are "deliberately thin shells around the tested core". `SocketServer` is not a shell: it is a stateful, fd-level, security-relevant component with a hand-rolled lifecycle. Its stop/start path is already the subject of a defensive comment ("Reset synchronously… Without this, stop()→start() … would no-op on the stale fd").

**Impact.** The highest-value regression surface in the daemon — the one a security review cares about — is unverified. Had the client serialization been tested, F5-style latent bugs in adjacent parsing would have surfaced earlier.

**Smallest correct way to close it.** Extract the pure parts so the existing test target can reach them, and add a small integration test that drives the real server over a temp-path socket (no root needed — `SocketServer` is internal but the *test target imports `MagSleepCore`, not the helper*; so the clean move is to promote the two pure decisions into `MagSleepCore`):

1. Move the request-size / newline-splitting decision into `MagSleepCore` as a pure function, e.g. `SocketFraming.takeLine(buffer:) -> (line: String?, exceededLimit: Bool)`, and unit-test it (partial line, exact 4096, 4097, embedded `\r`, multiple newlines).
2. Move the peer-authorization predicate to a pure `PeerAuthorization.isAllowed(peerUID:consoleUID:) -> Bool` in `MagSleepCore`; the daemon keeps only the `SCDynamicStoreCopyConsoleUser` lookup. Test: root⇒true, console⇒true, other⇒false, `nil` peer⇒false.
3. Add an integration test for the server in the helper target only if a test target is added for it; otherwise at minimum cover (1) and (2), which are where the decisions live.

**Acceptance test.** New tests asserting: a 4097-byte request is rejected; a request split across two TCP-less writes is reassembled; a peer uid that is neither root nor the console user is rejected; an undeterminable console user is rejected.

---

### F5 — Fat Mach-O parsing used both wrong entry strides, so a universal helper hashes to nil (Low, Correctness, Confidence High) — **FIXED, see §13**

**What happens.** `MachOContentHash.arm64Slice(in:)` (`:88-112`) walked fat containers with hard-coded widths:

```swift
let entryWidth = magic == 0xcafebabf ? 20 : 16          // :97  ← both wrong
…
let offset = Int(uint32(data, entryOffset + 8))         // :102 ← wrong for fat64
let size   = Int(uint32(data, entryOffset + 12))        // :103 ← wrong for fat64
```

Checked against the SDK header (`$(xcrun --show-sdk-path)/usr/include/mach-o/fat.h`) and the ABI:

| struct | size | `offset` | `size` |
|---|---|---|---|
| `fat_arch` | **20** | u32 @ +8 | u32 @ +12 |
| `fat_arch_64` | **32** | u64 @ +8 | u64 @ +16 |

So the 32-bit branch advanced 16 bytes per entry instead of 20, and the 64-bit branch advanced 20 instead of 32 while reading `offset` as two 32-bit halves and `size` out of `offset`'s high half. (My original finding named only the fat64 half of this; verifying the header showed *both* widths were wrong.)

**Why this matters more than the fat64 framing suggests.** The reachable case is not exotic fat64 — it is the ordinary universal binary produced by `lipo`/`xcodebuild`: `FAT_MAGIC` with 20-byte `fat_arch` entries and **arm64 conventionally second** after x86_64. With a 16-byte stride the reader lands mid-entry on the second iteration, fails the `CPU_TYPE_ARM64` test, and returns nil.

**Evidence (deterministic repro).** A probe compiled against the real module wrapped an identical thin arm64 Mach-O in each container:

```
thin  (MH_MAGIC_64)   : 9a12d05b5212e57103b7e32a189491b4de1a9c35a481a59bdb36649c259706ec
fat32 (FAT_MAGIC)     : 9a12d05b5212e57103b7e32a189491b4de1a9c35a481a59bdb36649c259706ec   (1 entry)
fat64 (FAT_MAGIC_64)  : nil
```

Single-entry containers do not exercise the stride, which is why the 32-bit defect survived the original probe; the tests added below cover arm64-as-second-entry, where it does surface.

**Impact (honest bounds).** The bundled helper is built thin arm64 (`build-app.sh:22-23` `--arch arm64`) and CI uses the same script, so this path is **dead in production today** — hence Low. Impact is latent: a non-thin helper yields a nil content hash, `HelperManager` silently falls back to the git-revision comparison (`:238-241`), and update detection degrades to the pre-1.3.3 behaviour that 1.3.3/1.3.4 were released to fix.

**Fix applied** (`Sources/MagSleepCore/MachOContentHash.swift`) — correct stride per variant, 64-bit reads for the 64-bit variant, an overflow-free bounds check, and a new `uint64` reader:

```diff
-            let entryWidth = magic == 0xcafebabf ? 20 : 16
+            let is64 = magic == 0xcafebabf
+            let entryWidth = is64 ? 32 : 20
             var entryOffset = 8
             for _ in 0..<nfat {
                 guard entryOffset + entryWidth <= data.count else { return nil }
                 let cputype = uint32(data, entryOffset)
-                let offset = Int(uint32(data, entryOffset + 8))
-                let size = Int(uint32(data, entryOffset + 12))
+                let offset = is64 ? uint64(data, entryOffset + 8)
+                                  : UInt64(uint32(data, entryOffset + 8))
+                let size = is64 ? uint64(data, entryOffset + 16)
+                                : UInt64(uint32(data, entryOffset + 12))
                 if cputype == 0x0100_000c { // CPU_TYPE_ARM64
-                    guard offset + size <= data.count else { return nil }
-                    return data.subdata(in: offset..<(offset + size))
+                    guard size <= UInt64(data.count),
+                          offset <= UInt64(data.count) - size else { return nil }
+                    let start = Int(offset)
+                    return data.subdata(in: start..<(start + Int(size)))
                 }
```

**Tests added** (`MachOContentHashTests`): a `fat(...)` fixture builder (20-byte vs 32-byte entries) plus four cases — arm64 first and arm64 *second*, in a 32-bit and a 64-bit container — all asserting the fat image hashes exactly like its thin arm64 slice. That suite is now 9 tests.

---

### F6 — The VirusTotal API key is passed in `curl` argv (Low, Security, Confidence High)

**What happens.** `scripts/virustotal-scan.sh:52-55`:

```bash
UPLOAD_JSON="$(curl -sS --max-time 30 -X POST \
    -H "x-apikey: $VIRUSTOTAL_API_KEY" \
```

A process's argv is world-readable on macOS (`ps -ww -o command=`) for the lifetime of that call. The key is therefore visible to any local user (or any process) during the upload and during each of up to 12 poll requests.

**Why it is wrong relative to the baseline.** Baseline #5: the project goes out of its way to keep the Sparkle key out of argv, with an explicit comment that "argv would leak into the process list". The VT helper does the opposite with a secret of the same class.

**Impact.** Bounded — a VirusTotal free-tier key has no write access to the release, and the CI runner is ephemeral — which is why this is Low and not Medium. It is still a genuine inconsistency with the project's stated policy, and the same pattern would be much worse if copied to a higher-value secret.

**Smallest correct fix.** Feed the header on stdin, which `curl` supports, so it never appears in argv:

```diff
-UPLOAD_JSON="$(curl -sS --max-time 30 -X POST \
-    -H "x-apikey: $VIRUSTOTAL_API_KEY" \
-    -F "file=@$FILE" \
-    "$API/files" 2>/dev/null || true)"
+UPLOAD_JSON="$(printf 'x-apikey: %s\n' "$VIRUSTOTAL_API_KEY" | curl -sS --max-time 30 -X POST \
+    -H @- \
+    -F "file=@$FILE" \
+    "$API/files" 2>/dev/null || true)"
```

(the two poll `curl` calls take the same treatment; only the header changes).

**Acceptance test.** Run the script with a dummy key and assert `ps -ww -o command= -ax | grep -c "<key>" ` is 0 while the analysis id is still returned.

---

### F7 — `disable()` while the daemon is down reports success but is not persisted (Low, Correctness, Confidence High)

**What happens.** `HelperManager.disable()` (`:398-412`):

```swift
guard isLoaded else {
    isEnabled = false          // local-only
    completion(true)           // user sees success
    return
}
```

Nothing is written to disk and no socket request is made. The persisted config still says `enabled = true`. Launchd's `KeepAlive` revives the daemon whenever it exits non-zero (baseline #10), and on revival `loadConfig()` sees `enabled = true` and re-applies the mode — silently undoing the user's "Disabled" choice.

**Impact.** A user who chooses **Disabled** during a window when the helper is down (e.g. right after an external kill, before recovery completes) is told it worked, then finds the LED unmanaged only until the daemon returns, at which point Sleep Mode silently resumes. The window is narrow and the recovery path (`checkDaemonRecovery`) usually repairs liveness first — hence Low.

**Smallest correct fix.** Record the intent durably even when the daemon is unreachable. The cleanest option consistent with the architecture is to write the config file directly (the app already *reads* it; `0644` means a root-owned file is not writable by the user, so this needs a different mechanism). Two pragmatic choices:

- **(a) Preferred — honest reporting:** treat "daemon down" as *not disabled* and surface it, rather than claiming success:

```diff
         guard isLoaded else {
-            isEnabled = false
-            completion(true)
+            // The daemon owns the persisted config; without it we cannot make
+            // the disable stick. Report failure so the menu can offer recovery.
+            lastError = "Helper is not running"
+            refreshAsync()
+            completion(false)
             return
         }
```

  The menu already handles this shape: `setDisabledMode` → `handleModeFailure` → offers "Reconnect" (`enable()`), which is the correct remedy.

- **(b) If local-success is genuinely desired:** add a socket-level command the daemon applies on next start (e.g. persist a `pendingDisable` flag in the config the app *can* write — but that requires changing the config ownership model and is a bigger change than the problem warrants).

**Acceptance test.** With the helper installed and stopped, choose **Disabled**: the app must not report success, and after the daemon is revived the menu must not show Disabled unless the user retries the action.

---

### F8 — A dropped system-wake event can leave the LED off indefinitely (Low, Robustness, Confidence High)

**What happens.** Sleep Mode turns the LED off on `systemWillSleep` and restores `.system` on `systemHasPoweredOn` (`MagSleepHelperMain.swift:350-365`). If that single IOKit message is dropped, `isSleeping` stays `true`; the 3 s re-assert (`:552-575`) keeps computing `LEDTarget.color(… isSystemSleeping: true …)` ⇒ `.off`, so the watchdog *reinforces* the stale state rather than healing it. `handleDisplayPowerMessage` only clears `isDisplayAsleep`, and `LEDTarget` returns `.off` for `.sleep` when *either* flag is set, so a display-wake cannot rescue it.

**Impact.** The LED stays off (or, in Always Off, the mode is unaffected) until the next sleep/wake cycle or a daemon restart. The user's escape hatch is the menu. Impact is cosmetic — the LED is the app's only output — hence Low, but it is a stuck state with a trivially available fix.

**Smallest correct fix.** The daemon already has the primitive: `currentSystemPowerState()` (`:599-608`) reads `State:/IOKit/PowerManagement/CurrentSystemPower` from the dynamic store. Cross-check it on the re-assert tick instead of trusting a flag forever:

```diff
     private func reassertActiveMode() {
         guard config.enabled else { return }
+        // Heal a dropped systemHasPoweredOn: the dynamic store is authoritative,
+        // so a stale isSleeping=true cannot pin the LED off indefinitely.
+        if isSleeping, currentSystemPowerState() == false {
+            log.info("re-assert: power state says awake, clearing stale sleep flag")
+            isSleeping = false
+        }
         applyMode()
     }
```

**Acceptance test.** Unit-testable only after the flag is fed through `LEDTarget` (already pure); a practical check is to kill-and-revive the daemon while awake and confirm it does not start in the `.off` state — which `isSystemSleeping()`'s seed already handles at startup, so the re-assert cross-check closes the mid-life case.

---

### F9 — `wait_for_job_gone` can never report failure (Low, Correctness, Confidence High)

**What happens.** `scripts/install-helper.sh:75-86`:

```bash
wait_for_job_gone() {
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! launchctl print "system/$LABEL" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
}
```

A bash `for` loop's exit status is the status of the last command executed in its body — here `sleep 0.5`, which is 0. So the function returns 0 even when the job is still loaded after 5 s. Reproduced:

```
$ f() { for _ in 1 2 3; do if false; then return 0; fi; sleep 0.01; done; }; f; echo $?
0
```

**Impact.** Low, and arguably benign: the caller wants "best-effort wait, never hang", and the enclosing bootstrap loop (3 attempts, each re-bootouting) covers the case. The defect is that the function's name and the comment ("wait until launchd has actually released the job") promise a guarantee it does not provide, which invites a future caller to rely on it. With `set -euo pipefail`, a *real* non-zero return would also abort the script — so the fix must pick a deliberate convention.

**Smallest correct fix.** Make the contract explicit:

```diff
-wait_for_job_gone() {
-    for _ in 1 2 3 4 5 6 7 8 9 10; do
-        if ! launchctl print "system/$LABEL" >/dev/null 2>&1; then
-            return 0
-        fi
-        sleep 0.5
-    done
+# Best effort: returns 0 once the job is gone, 1 if it is still loaded after
+# ~5s. Callers that can proceed anyway must use `wait_for_job_gone || true`.
+wait_for_job_gone() {
+    for _ in 1 2 3 4 5 6 7 8 9 10; do
+        launchctl print "system/$LABEL" >/dev/null 2>&1 || return 0
+        sleep 0.5
+    done
+    return 1
 }
```

and at the call sites either keep the existing tolerance (`wait_for_job_gone || true`) or fail loudly on the pre-bootout call, which is where a still-loaded job actually causes the EIO the script is trying to prevent.

**Acceptance test.** A shell test that loads a dummy job, calls the function, and asserts the return code is 1 after the timeout.

---

### F10 — The install-time integrity pin is self-referential (Low, Security, Confidence Medium)

**What happens.** `build-app.sh:105-114` signs the bundled helper, records its cdhash into `Contents/Resources/helper-cdhash.txt`, and signs the bundle so the file is sealed. `install-helper.sh:41-65` then verifies, before any privileged write: (1) `codesign --verify --deep --strict "$BUNDLE"`, and (2) that the bundled helper's cdhash equals the pin read from the **same bundle**.

**Why it is weak.** Both checks are satisfied by anyone able to write the app bundle: replace `magsleep-helper`, rewrite `helper-cdhash.txt` to the new cdhash, re-sign ad-hoc (the app is ad-hoc signed, so there is no trusted identity to forge), and both checks pass. The pin proves only that *this bundle's own helper* matches *this bundle's own recorded value*.

**Honest impact.** Low, and I want to be precise rather than alarmist. Writing to `/Applications/MagSleep.app` requires admin, and the attacker must also get the user to trigger an install and type their password — at which point they could simply `sudo`. So this is not a privilege-escalation path; it is a *weakening* of the stated guarantee in `SECURITY.md`-adjacent comments ("a modified or corrupted app can no longer install a tampered root daemon", CHANGELOG 1.3.2). The truthful statement is: *partial* tampering is caught; wholesale replacement is not.

**Confidence: Medium.** I verified the mechanism by reading both scripts and confirmed the bundle is ad-hoc (`codesign -dvvv` → `Signature=adhoc`, `TeamIdentifier=not set`). I did **not** build a tampered bundle end-to-end (that would require a privileged install). Doing so would raise confidence to High.

**Smallest correct improvement (documentation-first, then mechanism).**

1. Fix the claim in the CHANGELOG/comment to say what is actually guaranteed.
2. If a real guarantee is wanted, the anchor must live outside the bundle under attack. The cheapest option that fits the architecture: have `install-helper.sh` also require that the *installed* helper (if any) and the *bundled* helper are the only acceptable sources, and record the pin in `$CONFIG_DIR` (root-owned, mode 0644) written by the daemon on first install — so replacing the app bundle cannot also rewrite the pinned value. A stronger option is a Developer ID signature with a pinned Team ID, which is out of scope (baseline #9).

**Acceptance test.** With a pin stored outside the bundle: modify `Contents/Resources/magsleep-helper`, refresh `helper-cdhash.txt`, re-sign the bundle, run the installer — it must refuse.

---

### F11 — Actions pinned to mutable major tags (Low, Supply chain, Confidence Medium)

**What happens.** `.github/workflows/release.yml:42` `actions/checkout@v7`, `:135` `actions/attest@v4`; `.github/workflows/codeql.yml:30` `actions/checkout@v7`, `:32/:36/:38` `github/codeql-action/{init,autobuild,analyze}@v3`. Major tags are mutable: whoever controls those repositories can move `v4` to new code, which then runs with `contents: write`, `id-token: write`, and `attestations: write` in the release job.

**Impact.** This is the standard GitHub Actions supply-chain caveat, and it is materially more relevant here than in a typical repo because (a) the workflow holds the app's update-signing key, and (b) the project explicitly sells provenance ("provably GitHub-built"). Pinning to commit SHAs with a comment is the recognised mitigation.

**Smallest correct fix.**

```diff
-      - uses: actions/checkout@v7 # v4 targets deprecated Node 20
+      - uses: actions/checkout@08eba0b27e820071cde6df949e0beb9ba4906955 # v4.3.0
```

(with the real SHAs resolved per action; add Dependabot or `renovate` config so the pins stay current). Effort is minutes.

**Acceptance test.** A CI job (or pre-commit check) asserting every `uses:` line in `.github/workflows/` ends in a 40-hex-char ref.

---

### F12 — Bot author email typo in the feed-repair path (Low, Correctness, Confidence High)

**What happens.** `.github/workflows/release.yml:100` sets `git config user.email "magleep[bot]@users.noreply.github.com"` — `magleep`, missing the `s`. The other two bot-identity sites (`:231-232` and the repair path's `user.name`) use `MagSleep Release Bot`; only this one email is wrong, so repair commits are attributed to a non-existent bot account.

**Impact.** Cosmetic/attribution only. Linting-level.

**Smallest correct fix.**

```diff
-          git config user.email "magleep[bot]@users.noreply.github.com"
+          git config user.email "magsleep[bot]@users.noreply.github.com"
```

**Acceptance test.** `grep -rn "magleep" .github/` returns nothing.

---

### F13 — Main-thread socket probe at launch and on first `get led status` (Low, Performance, Confidence Medium)

**What happens.** `HelperManager.init()` calls `refresh()` (`:74-93`), which calls `HelperConnection.probe()` — a synchronous non-blocking connect with a 1000 ms poll. The controller constructs the manager on the main thread inside `applicationDidFinishLaunching` (`MagSleepApp.swift:36,65`). Separately, `AppleScriptCommands.GetLEDStatusCommand` (`:84-95`) uses a lazily created `ScriptStatusHelper.shared = HelperManager()`, whose first use runs the same probe on the main thread (AppleScript handlers run there).

**Impact.** Small and bounded. When the daemon is up, a local `connect()` completes in microseconds. It is the *absent or backlogged* cases that cost up to a second of frozen menu bar, and the codebase elsewhere is explicit that probes belong off-main (`refreshAsync`'s doc comment says exactly that). Hence Low.

**Confidence: Medium.** I verified the call path statically. I did **not** measure a stall, because reproducing the ~1 s case needs a socket that exists but does not answer (e.g. a listener with a full backlog), which I could not stage without touching the live helper. A measurement with a stalled listener would raise it to High.

**Smallest correct fix.** Use the async path for the initial load (the controller already reacts to the resulting state change):

```diff
     init() {
-        refresh()
+        refreshAsync()
     }
```

and in `GetLEDStatusCommand`, keep the shared instance but perform the first refresh off-main, or simply accept the disk read (`refreshFromDisk()` already avoids the probe) plus a one-time async probe fired at app launch.

**Acceptance test.** `swift run`-equivalent launch with the helper stopped: `sample MagSleep 2` shows no main-thread `connect` frame at launch.

---

### F14 — `BoundedProcess` leaves drain tasks unjoined on the launch-failure path (Low, Robustness, Confidence Medium)

**What happens.** `BoundedProcess.run` (`:40-54`) queues the two `drain` closures *before* `try process.run()`. If `run()` throws, the function returns early — the two drains were never joined (`queue.sync {}` is skipped) and the boxes they write into are still exclusively accessed by them. Harmless in practice (they observe EOF from the closed write ends and exit), but the invariant "all queued work is joined before return" is broken on exactly the path where something has already gone wrong.

**Impact.** No leak that matters (the closures complete and are released), and the returned stdout/stderr are correctly empty. This is an invariant/cleanliness defect, not a resource leak. Recorded because it is cheap to fix and because `BoundedProcess` is shared, load-bearing plumbing.

**Smallest correct fix.**

```diff
         do {
             try process.run()
         } catch {
             stdoutPipe.fileHandleForWriting.closeFile()
             stderrPipe.fileHandleForWriting.closeFile()
+            queue.sync {} // join the drains so they never outlive run()
             return BoundedProcessResult(terminationStatus: -1, stdout: Data(), stderr: Data(), timedOut: false)
         }
```

**Acceptance test.** Extend `BoundedProcessTests` with a non-existent `executableURL` and assert it returns promptly with `terminationStatus == -1` and does not trap on exclusivity (run under `swift test` with exclusive-access checking on).

---

### F15 — Deprecated activation APIs on the project's own minimum OS (Low, Compatibility, Confidence High)

**What happens.** `StatusItemController.swift:105` `NSApp.activate(ignoringOtherApps: true)` and `MagSleepApp.swift:51` `existing.activate(options: [.activateAllWindows])` are both deprecated as of **macOS 14.0** — the exact deployment target in `Package.swift`. They still compile and work, and the codebase is otherwise careful about deprecation (it bumped `actions/checkout` for a Node-20 warning).

**Impact.** No functional impact today; a future SDK may remove them, and the deprecation warning is one of the few things `-warnings-as-errors` could start rejecting on a toolchain bump.

**Smallest correct fix.**

```diff
-        NSApp.activate(ignoringOtherApps: true)
+        NSApp.activate()
```

```diff
-            existing.activate(options: [.activateAllWindows])
+            existing.activate()
```

**Acceptance test.** `swift build -c release --arch arm64 -Xswiftc -warnings-as-errors` stays clean (already the pre-commit gate).

---

### F16 — "Night Schedule" is actionable when it cannot work (Low, UX, Confidence Medium)

**What happens.** `nightScheduleItem` (`StatusItemController.swift:367-375`) is always enabled and always gets a target/action. When the helper is not loaded (`toggleNightSchedule:453-457`) or Disabled, pressing it produces a `showError` alert rather than a disabled-looking item. Compare `launchAtLoginItem`, which correctly sets `isEnabled = helper.canManageLaunchAtLogin` (`:307`).

**Impact.** Minor friction: a toggle that looks available and then explains it isn't. Also, toggling Night Schedule while Disabled persists a value with no effect until the helper is re-enabled — arguably correct, but invisible.

**Confidence: Medium.** Pure UI behaviour, read from code; I could not click the menu in this environment.

**Smallest correct fix.** Gate the item the way its sibling is gated:

```diff
         nightScheduleItem.target = self
         nightScheduleItem.action = #selector(toggleNightSchedule)
+        // Only meaningful while the daemon is running and enabled.
+        nightScheduleItem.isEnabled = helper.isLoaded && helper.isEnabled
         nightScheduleItem.state = helper.nightScheduleEnabled ? .on : .off
```

and set the same flag in `updateMenuStates()`.

**Acceptance test.** With the helper stopped, the item renders dimmed and is inert.

---

### F17 — README menu reference has drifted from the menu (Low, Docs, Confidence High)

**What happens.** The README's menu table (`README.md:119-130`) lists Sleep Mode / Always Off / Disabled / Launch at Login / Check for Updates… / Report a Problem… / Buy me a coffee / Uninstall MagSleep… / About MagSleep… / Quit MagSleep. Two mismatches against `createMenu()` and `addSettingsToggles()`:

- **Night Schedule is missing** from the table, although it is a documented feature (`:32`) and a real menu item.
- **"Report a Problem…"** renders with an ellipsis in the README, but the item title is `"Report a Problem"` with none (`StatusItemController.swift:325` — and the code comment explicitly argues against the ellipsis: *"no ellipsis: it takes no further input"*).

`AGENTS.md`'s `StatusItemController` summary enumerates the menu and likewise omits Night Schedule.

**Impact.** Documentation drift that makes the app look less capable than it is; the ellipsis case is a HIG-consistency claim the code deliberately contradicts.

**Smallest correct fix.** Add a Night Schedule row to the README table and drop the ellipsis:

```diff
 | **Disabled** | Hand the LED back to macOS entirely |
+| **Night Schedule** | Keep the LED off from sunset to sunrise |
 | **Launch at Login** | Start MagSleep when you log in |
 | **Check for Updates…** | Check for updates via Sparkle (also checked automatically twice a day) |
-| **Report a Problem…** | Open the GitHub issue tracker with your app version + helper revision pre-filled |
+| **Report a Problem** | Open the GitHub issue tracker with your app version + helper revision pre-filled |
```

and add Night Schedule to the AGENTS.md menu list.

**Acceptance test.** A doc test that greps `createMenu` item titles and asserts each appears in the README table (optional, but this drift has now happened twice).

---

### F18–F22 — Informational

**F18 (`Package.swift:1` vs `README.md:14`).** The README badge reads "Swift 6" while the manifest is `swift-tools-version:5.10` and `AGENTS.md` says Swift 5.10. The toolchain is Swift 6 building a 5.10-language-mode package, so both statements are defensible; they are just not the same statement. Suggest the badge read "Swift 5.10" (or the manifest be bumped deliberately).

**F19 (`build-app.sh:10,70-79`; `release.yml:30-33`).** `BUILD_NUMBER="$(date +%Y%m%d%H%M)"` is baked into `Info.plist` and `build-info.json`, so two builds of one commit differ byte-for-byte. The workflow comment "Pinned (not macos-latest) for **reproducible release bytes**" therefore overstates what is achieved: pinning gives a *stable environment*, while the timestamp guarantees non-identical bytes. Provenance (the attestation) is what actually holds. Either say "pinned for a stable build environment" or derive the build number from the commit/run (e.g. `GITHUB_RUN_NUMBER`) and make reproducibility a real, testable goal.

**F20 (`apply-vt-proof.py:20`).** `version, badge, label, permalink = sys.argv[1:5]` raises `ValueError`/`IndexError` on a malformed call, producing a traceback rather than a clear message. Called correctly by CI, so Info — but it is the one script in the tree without an argument guard, and every shell sibling has one:

```diff
-    version, badge, label, permalink = sys.argv[1:5]
+    if len(sys.argv) < 5:
+        print("usage: apply-vt-proof.py VERSION BADGE LABEL PERMALINK", file=sys.stderr)
+        return 2
+    version, badge, label, permalink = sys.argv[1:5]
```

**F21 (`Sources/MagSleep/*`).** The daemon logs well (`os.log`, `Logger`, categories, throttled SMC failures, `privacy: .public` peer uids). The app has no logger: install/update failures end up in `lastError` and an `NSAlert`, or a single `NSLog` in `UpdateManager` (`:48`). When a user reports "the helper wouldn't install", nothing on the machine records why. The fix is small and does not add any user-visible surface (so it does not collide with the project's "no debug UI" rule): adopt the same `Logger(subsystem: "com.magsleep.app", category:)` pattern in `HelperManager.runPrivilegedScript` and `confirmConnection`, logging the osascript stderr and the confirmation outcome. A "Copy diagnostics" affordance was previously *removed* (1.2.2) as a user-visible debug item — keep this purely in the log.

**F22 (`SocketServer.swift:81,154-158`).** `listen(fd, 8)` plus a 32-client cap that *closes* excess connections means a same-user process opening 32 stalled connections can transiently make the app's mode change fail (the app surfaces a "Reconnect" prompt). Same-user, self-inflicted, and recoverable — noting it for completeness rather than as a vulnerability. If it ever mattered, the idle sweep interval (10 s) is the lever.

---

## 7. Test-coverage & quality gaps

**What is covered well.** The pure core is genuinely well tested: config decode/fallback/forward-compat, the full `LEDTarget` precedence matrix including night-vs-disabled, request→config transitions with adversarial inputs (whitespace, case, empty), the socket JSON round-trips including malformed/CRLF/unknown-field cases, the SMC struct stride *and* per-field offsets, `fourCC`, `MacOContentHash`'s signing-independence, `HelperVersioning`, `SunSchedule` against captured real output, and `DayNight` boundaries. 95 tests, 1.35 s — a fast enough suite that there is no excuse not to extend it.

**Critical paths with no coverage at all:**

| Untested surface | Why it matters | Lightweight way to close it |
|---|---|---|
| `SocketServer` (accept, framing, caps, sweep, rebind, stop/start) | IPC **and** the authorization boundary | Extract framing + auth predicates into `MagSleepCore` and unit-test them (F4); add a temp-path integration test in a helper test target |
| `PowerDaemon.isAllowedPeer` | The actual authorisation decision | Pure `PeerAuthorization.isAllowed(peerUID:consoleUID:)` + tests (root, console, other, nil, undeterminable console) |
| `PowerDaemon.applyMode` dedup rule | "`.off` always re-asserted, `.system` deduped" is subtle and load-bearing | Extract the decision `shouldWrite(target:lastWritten:) -> Bool` (or assert via `LEDTarget` + a tiny helper) and test the four combinations |
| `HelperManager` version decision wiring | 3 regressions in 6 months lived here | `HelperVersioning` is tested; test the *precedence* (content hash first, revision fallback) as a pure function |
| `MachOContentHash` fat / fat64 path | F5 lives exactly here | Add the two fat cases to `MachOContentHashTests` |
| `OnboardingWindowController` | Mandatory, unskippable install flow | Hard to unit-test (AppKit); at minimum a smoke test of `ModeCardView`'s selection state and the `didFinish` idempotency guard |
| `BoundedProcess` launch-failure path | F14 | One test with a bad `executableURL` |
| `install-helper.sh` lock/retry logic | Highest-churn script | A shell test with a stubbed `launchctl`/`lockf` on `PATH` |

**Missing test *kinds*.** No property-based or fuzz testing anywhere. Two places would benefit cheaply: (a) the config decoder (round-trip arbitrary `DaemonConfig` values, and arbitrary plists must never crash); (b) `MachOContentHash.hexSHA256(of:)` fed random/truncated bytes — it already guards bounds, and a fuzz pass would prove it (the parser reads `uint32` at attacker-influenced offsets; every read is guarded today, but that is exactly the property fuzzing confirms).

**Flakiness risk.** `BoundedProcessTests.testGrandchildHoldingPipeDoesNotHang` asserts wall-clock bounds (`< 2.5 s`) and `testHungProcessTimesOut` asserts `< 5 s`. Generous, but they are the only timing-dependent tests. `DayNightTests.testFallbackWindowLocalHours` (`MagSleepCoreEdgeCaseTests.swift:384-398`) builds times with `Calendar.current` — on a machine whose system calendar is not Gregorian this test becomes meaningless. Pinning an explicit `Calendar(identifier: .gregorian)` would remove both the flake and the locale dependence.

**Tests asserting implementation details.** The SMC offset assertions (`MagSleepCoreArchitectureTests.swift:286-296`) are deliberately layout-pinning — correct here, because the layout *is* the contract with the kernel. Not a smell.

---

## 8. Correct by design — do not change

Things that look wrong and are not. The next agent should leave these alone.

1. **`KeepAlive { SuccessfulExit: false }` + SIGTERM handler that restores `.system` and `exit(1)`.** A kill intentionally returns the LED to macOS for a moment, then launchd revives the daemon and it re-applies the active mode. This is a *wanted* observable behaviour, not a flicker bug. Do not "fix" it by making shutdown clean, and do not weaken the revive.
2. **`uninstall-helper.sh` uses `set -uo pipefail` without `-e`.** Deliberate: cleanup must remove what it can and never abort midway. Similarly, `[ -x "$BIN" ] && "$BIN" --reset || true`.
3. **The socket is `chmod 0666`.** Intentional (the app connects as the console user) with authorization performed per-request via `getpeereid`. Changing it to `0600` would break the app; the uid check, not the mode, is the control.
4. **`chmod()` by path rather than `fchmod()` on the fd.** `fchmod` on a unix-socket fd fails with `EINVAL` on macOS; the comment records this. Leave it.
5. **The version menu item is greyed with no action.** AppKit dims any `NSMenuItem` without a target/action; the dimmed header is the intended look, and a no-op action would be needed to un-dim it — which is precisely what is *not* wanted here.
6. **`SocketResponse.id` is set and never read by the client.** Documented as kept for request/response correlation (and the working tree already replaced the stale `periphery:ignore` with a plain comment).
7. **`--reset` exits 0 while normal operation exits 1.** `--reset` is a one-shot invoked by the uninstaller; it must not be resurrected by `KeepAlive`, so 0 is correct.
8. **`AppleScriptCommands.sendLEDCommand` blocks a semaphore on the main thread while a background queue performs the send.** Correct: the completion never hops back to `main`, so there is no deadlock. The comment explains it; do not "modernise" it into an async/await that resumes on the main queue.
9. **Missing `config`/`error` JSON keys when nil.** Swift's synthesized `Codable` omits `nil` optionals; the client decodes them as `nil`. The wire vocabulary is still unambiguous. Do not add `"config": null` by hand.
10. **`sleepimage` mtime heuristic.** Used only once, at startup, to seed `isSleeping` when launchd revives the daemon mid-sleep — and explicitly `??`-guarded by the authoritative dynamic-store read. It is not the ongoing sleep detector.
11. **The 3 s re-assert timer writing `.off` every tick in Always Off / at night, while deduping `.system`.** macOS genuinely flips the LED on plug/unplug and a failed write must be retried, so `.off` must be re-asserted; `.system` cannot be flipped by anything, so skipping it removes ~28,800 pointless writes/day. Both halves are deliberate.
12. **`#if !arch(arm64)` refusal and the `ACLC`-support check.** Intel is explicitly unsupported; the binary still builds so users get a clear message rather than a crash.
13. **Ad-hoc signing, no notarization, Gatekeeper friction.** A documented cost of not paying for a Developer ID; the README walks users through the four unblock methods. Sparkle accepts the updates because the EdDSA public key is unchanged.
14. **`// periphery:ignore` directives retained after the Periphery→Lethen rename.** Lethen keeps the directive vocabulary; the per-field ignores on C-interop struct fields are still required. Do not strip them (but do remove any that Lethen now reports as superfluous — `--strict` fails on a superfluous ignore).
15. **`RunLoop.main.add(timer, forMode: .common)` for the app's refresh timer but `.default` for the daemon's timers.** The app's timer must keep firing while a menu is open (event-tracking mode); the daemon has no menus.
16. **`HelperManager` not being `@MainActor`.** Documented: it is constructed from non-isolated AppKit entry points and all its mutations happen on the main queue anyway.

---

## 9. False-Positive Log

Eight things that looked like defects and were dismissed, with the precise reason. This section exists so the next reader can trust the calibration rather than the volume.

1. **"`BoundedProcess` captures local `Data` boxes with `&` inside `queue.async` — that's a data race / exclusivity trap."** Dismissed. Each drain closure takes a *different* variable, and the main thread only reads them after `queue.sync {}`, which is a barrier that waits for both. The exclusive accesses never overlap, so no trap and no race. Confirmed by `testGrandchildHoldingPipeDoesNotHang` passing and by the code compiling under the standard check.

2. **"The daemon restarts after SIGTERM, so the LED flickers — a bug."** Dismissed. Intentional (`KeepAlive { SuccessfulExit: false }`); the brief return to macOS control is a feature the maintainer wants to observe. Do not change (baseline #10).

3. **"The world-writable unix socket is a local privilege-escalation hole."** Dismissed. The socket mode is 0666 by design, and authorization is per-request via `getpeereid` compared against the console user, failing closed when the console user cannot be determined. Verified live: an unauthorized *command* (unknown) is still parsed and answered by the daemon, which means the accept/read/respond path works independently of authorization — and the authorization gate itself rejects non-console peers. Mode 0666 is the transport, not the control.

4. **"`codesign --verify --deep --strict` on an ad-hoc bundle must fail, so the install integrity check is broken."** Dismissed, with evidence: `codesign --verify --deep --strict dist/MagSleep.app` → **exit 0** ("valid on disk / satisfies its Designated Requirement"). `codesign --verify` validates *structural integrity and the seal*, not trust; `spctl` is the one that enforces trust. The ad-hoc bundle verifies fine. (The *scope* limitation of the pin is a separate, real finding — F10.)

5. **"`SocketServer.stop()` then `start()` can close the newly created listening fd, because the cancel handler closes a captured fd number that could be reused."** Dismissed. `stop()` resets `listenFD = -1` *synchronously* and the cancel handler only clears `listenFD` if it still equals the captured value; moreover the old fd is still open when `start()` calls `socket()`, so the new fd cannot collide with it. The comment in `stop()` documents exactly this reasoning.

6. **"`UnixSocket.makeSockAddr` silently truncates over-long paths."** Dismissed. It computes `count = min(bytes, size-1)` but then `guard count == pathBytes.count else { throw Error.pathTooLong }` — so it *throws* rather than truncating. Covered by `testMakeSockAddrRejectsTooLongPath`. The misleading part is only the doc comment ("truncated at the platform path limit"), not the behaviour.

7. **"`SunSchedule`'s regex will match `nextSunrise`/`previousSunset`."** Dismissed. The pattern is anchored `(^|\n)\s*<key> = "` with `\s*` in between, so a line starting with `nextSunrise` cannot satisfy it. There is a dedicated test (`testAnchoredParseIgnoresSiblingKeys`).

8. **"`release.sh` stages `CHANGELOG.md` even though it does not modify it — a bug."** Dismissed. `git add README.md CHANGELOG.md Makefile` is harmless and intentional: the changelog must already contain the section (validated three lines earlier), and staging it makes the release commit self-describing.

Two further candidates were dismissed without needing evidence, worth recording so they are not re-raised: the single direct dependency (**Sparkle 2.9.5, pinned** — healthy, not stale) and the absence of an `SBOM` (**the Sigstore attestation covers provenance; an SBOM would be a nice-to-have, not a gap** — carried forward as an improvement, not a defect).

---

## 10. Cross-cutting observations

**One theme explains most of the churn: the helper install/update lifecycle is the system's true complexity, and it is the least tested.** Of the 75 commits in the window, the overwhelming majority touch `install-helper.sh`, `build-app.sh`, `release.sh`, `HelperManager`, the helper plist, or the update-detection logic — and three of the eight releases in the last two months were re-fixing a previous fix in this area (the 1.3.2 cdhash check removed in 1.3.3; the macOS-27 vmsize false-prompt in 1.3.4; the boot-time admin prompt in 1.3.5). Meanwhile the pure core, which *is* tested, has not produced a regression in the same period. The correlation is not a coincidence: this project has been relying on reasoning where it should be relying on executable tests, precisely where the blast radius is largest (root daemon installation). F4 is the single highest-leverage fix in this report.

**Consistent, deliberate error-handling style — and one gap.** `MagSleepCore` is uniformly "fail closed, degrade gracefully": corrupt config heals to defaults, unavailable sun schedule falls back to a fixed window, failed SMC writes drop the connection and retry, a failed bootstrap keeps the previous revision file so the app re-prompts. That style is applied consistently and is a strength. The gap is on the *reporting* side: `lastError` is a single untyped string that both the AppleScript bridge and three different alert paths reconstruct independently, and the app never writes it anywhere durable (F21). As a result the user-visible failure and the machine-visible cause can diverge — which is exactly what happened across the 1.3.x install regressions, where users saw generic "Bootstrap failed" text and the diagnosis had to come from reasoning about launchctl semantics.

**Documentation is unusually good and drifts at the low-value edges.** ARCHITECTURE.md and STRUCTURE.md are genuinely accurate about the invariants that matter (the two-process split, the wire vocabulary, the helper-revision computation, the fail-closed posture) — so accurate that they read like they were written by the same reasoning that produced the code. The drift is confined to user-facing enumerations: the README menu table (twice now, F17) and a couple of inline comments that describe an intended design rather than the shipped one (F2's "the status icon keeps signaling", and the "reproducible release bytes" claim behind F19). Both classes are cheap to close and worth closing, because the comment-without-code case is the one that misleads a future maintainer.

**The security posture is stronger than a typical hobby menu-bar app, with two inconsistencies.** The project does full-bundle signature verification, a build-time cdhash pin, xattr hygiene for macOS 27 launchd, per-request peer-uid authorization, a fail-closed console-user lookup, `privacy: .public` on non-sensitive log fields, Sigstore build attestation, and an explicit "never in argv / never on disk" policy for the update-signing key. The two inconsistencies are both about *scope* rather than mechanism: the key that policy protects is then handed to every step of the release job (F1), and a same-class key is put in `curl` argv one script over (F6). The fix in both cases is a one-line scoping change, which makes them cheap to close and worth closing precisely because the surrounding posture is otherwise exemplary.

**Complexity is concentrated in two files and it shows.** `StatusItemController.swift` (756 lines, 23 commits) mixes menu construction, four different alert flows, About-view layout code, `NSTextViewDelegate` conformance, and the Sparkle wiring; it is also where F2 and F16 live. It passes SwiftLint only because `type_body_length.error` was raised to 1200 — the config comment acknowledges the shape ("menu-bar controller naturally holds menu + state + prompt logic in one file"). That is a defensible choice at this size, but the About-view builder alone (`makeAboutAccessoryView`, ~50 lines of text-view geometry) has nothing to do with the menu and is the kind of thing that wants a tiny extraction. `HelperManager` (556 lines) is similar: config loading, binary hashing, version comparison, privileged execution, and socket I/O in one type, of which only the version comparison is testable today.

**No concurrency defects were found, and this appears to be by construction rather than by luck.** Both processes confine all mutable state to the main run loop / main queue; the socket server's dispatch sources are created with `queue: .main`; the daemon's comment says outright that `SMC.Connection` is "not thread-safe; call from a single thread (the daemon only touches it from the main run loop)"; and the only cross-thread handoffs (`fetchSunSchedule`, `confirmConnection`) hop back to `main` before touching state. The one place that could have gone wrong — the AppleScript bridge — was deliberately built to avoid a main-thread deadlock. Worth preserving this invariant explicitly in ARCHITECTURE.md, because it is the property that makes this codebase safe to modify.

---

## 11. Feature & improvement opportunities

Rated by value-to-effort. These are suggestions grounded in the existing architecture and its stated non-goals — not defect fixes. The README's non-goals (notarization, Shortcuts, Notification Blink) are respected: nothing here requires a paid Developer ID or the App Intents metadata pipeline.

### Quick wins (hours, low risk)

| # | Idea | Need it fills | Where it hooks in | Effort | Risk |
|---|---|---|---|---|---|
| Q1 | **"Update helper now" menu item when `needsUpgrade`** | Closes F2 properly: gives the user a deliberate, discoverable action instead of relying on the icon alone | `StatusItemController.createMenu` + `updateMenuStates`; calls the existing `helper.install` | S | None — reuses the existing install path |
| Q2 | **Extend the AppleScript dictionary with `get led status` fields** (`installed`, `running`, `enabled`, `mode`, `nightSchedule`, `helperUpToDate`) | Automation users currently must parse one English sentence; Rich scripting makes MagSleep scriptable in a maintainable way | `packaging/MagSleep.sdef` + `GetLEDStatusCommand` — the data already exists on `HelperManager` | S | Low — additive; AppleScript consumers are rare, so no breakage |
| Q3 | **A `--status` one-shot on the helper** (prints JSON config + version, exits 0) | Makes the daemon inspectable without the app; useful for bug reports and for support ("run this and paste the output") | `MagSleepHelperMain.main` next to `--reset`, reusing `DaemonConfig.load` | S | Low — read-only, no privilege change |
| Q4 | **`make doctor`** that reports installed/bundled helper hashes, revisions, socket state, launchd state, and xattrs | Every 1.3.x regression required reasoning about these exact facts; a single command would have answered each in one line | New `scripts/doctor.sh`; the primitives all exist (`MachOContentHash` is Swift, so shell would shell out to `codesign -dvvv` / `shasum`) | S–M | Low — read-only |
| Q5 | **App-side `os.log` logging** (F21) | Reconstructable user failures | `HelperManager.runPrivilegedScript` / `confirmConnection` | S | None |
| Q6 | **Pinned action SHAs + Dependabot** (F11) | Supply-chain hygiene the project already claims | `.github/workflows/*`, `.github/dependabot.yml` | S | None |
| Q7 | **An SBOM on each release** (`anchore/sbom-action` → attach `sbom.spdx.json`) | Completes the provenance story the attestation starts; downstream consumers can enumerate the single dependency | `release.yml` after the build | S | Low |

### Bigger bets (days, moderate risk)

| # | Idea | Need it fills | Where it hooks in | Effort | Risk |
|---|---|---|---|---|---|
| B1 | **A testable helper-lifecycle core** — extract the install/update decision (content-hash vs revision precedence, "is installed", "needs upgrade"), the socket framing, and peer authorization into pure, unit-tested `MagSleepCore` types; leave the daemon a thin executor | Turns the single highest-regression area in the project into covered code (see §10) | New `MagSleepCore` types + a helper test target; `SocketServer`/`HelperManager` delegate to them | M–L | Medium — a real refactor across the process boundary; must preserve the `@main` entry point for Lethen |
| B2 | **Integration test harness for the socket protocol** — a test that starts the real `SocketServer` on a temp path, connects with the real `HelperConnection`, and exercises success / unknown command / oversized / idle-sweep / rebind | Pins the IPC contract end-to-end, including the 4096-byte cap and the one-request-per-connection rule that the app depends on | Needs `SocketServer` importable from tests (B1 gives this) | M | Medium |
| B3 | **Battery-aware / thermal-aware sleep LED** — optionally leave the LED under macOS control when the Mac is running on battery, or surface amber-charging state | The current feature set treats *why* the LED is on as irrelevant; a "only hide the LED when charging" refinement is a natural product extension and needs no new privilege | `LEDTarget.color` gains an input (power source is already available via `IOPS`); the daemon already has the run-loop source | M | Medium — product decision, not a bug; needs a menu affordance and config key |
| B4 | **Cap and rotate the daemon log** | `/Library/Logs/MagSleep/helper.log` currently grows unbounded; the plist sets a `filesize` rlimit (10 MiB) but nothing manages rotation | `com.magsleep.helper.plist` (StandardOut/ErrorPath) — launchd has no built-in rotation, so a small write-side cap or a `newsyslog.d` entry | M | Low — an `newsyslog` config is the low-risk route |
| B5 | **Reproducible release bytes** (F19) — derive `CFBundleVersion` from the commit/run rather than the wall clock, then *prove* it by building twice in CI and comparing hashes | Turns "pinned runner" from a claim into a verified property; a real differentiator for a security-conscious audience | `build-app.sh:10`, plus a CI `rebuild-and-compare` step | M | Medium — the ZIP/DMG will never be bit-identical (hdiutil timestamps), so scope the claim to the `.app` payload |
| B6 | **Signed-identity roadmap note** — a short ADR recording why ad-hoc signing is accepted, what it costs, and what changes if a Developer ID is ever obtained (Notification Blink revival, AX-grant stability, notarization) | The two removed features were removed *because* of this constraint; a future maintainer should not re-discover it the hard way | New `docs/adr/` (note: `docs/` is gitignored — put it under `Documentation/` or un-ignore it) | S–M | None |
| B7 | **Expand the sun-schedule fallback into a first-class setting** — a manual "night starts at / ends at" time pair | `corebrightnessdiag` is undocumented and may vanish; a user-facing manual window makes the feature robust and is more honest than a hard-coded 20:00–07:00 | New config keys + `DayNight` already takes a `fallbackWindow` parameter; the menu has a settings section | M | Low–Medium — another config key to version, but the additive-decode pattern is already established |

**Speculative (flagged as such, not recommended yet):** a Homebrew cask was removed in 1.2.3 for Gatekeeper reasons — that decision stands until notarization exists, so it should not be revisited. A CLI wrapper around the socket is easy but would duplicate the AppleScript surface for no clear audience.

---

## 12. Suggested work order

Each item is an executable task with its acceptance criterion. Ordering is by value-to-effort and by blast radius, not by finding ID. Items 1–4 are the ones I would do this week.

1. **Unblock the release flow (F3).** Commit `ARCHITECTURE.md`/`STRUCTURE.md` and finish the Periphery→Lethen rename in one commit; decide explicitly what to do with `AUDIT_REPORT.md` (commit or remove — an untracked file blocks `make release`).
   *Accept:* `git status --porcelain` is empty; `scripts/release.sh 0.0.0` passes the clean-tree guard.

2. **Scope the release secrets to their steps (F1).** Move `VIRUSTOTAL_API_KEY` to the `VirusTotal scan` step and `SPARKLE_EDDSA_KEY` to the `Sign Sparkle appcast` step; pass `GH_TOKEN` per-step instead of job-wide.
   *Accept:* a probe step immediately after `Run tests` finds both variables unset; the signing step still produces an entry with `sparkle:edSignature`.

3. **Make the outdated helper visible (F2).** Add the `needsUpgrade` branch to `statusImage()` and `statusTitle()` (and optionally the Q1 menu item).
   *Accept:* with a mismatched helper, choosing **Later** leaves the icon changed and the tooltip reading "Helper update available"; `updateMenuStates()` picks it up without extra plumbing.

4. **Cover the socket boundary (F4 + B1 + B2).** Extract the framing and peer-authorization decisions into `MagSleepCore`, unit-test them, then add a temp-path integration test for `SocketServer`.
   *Accept:* new tests prove a 4097-byte request is rejected, a split line is reassembled, root/console peers are allowed and others rejected, and an undeterminable console user is rejected. `make test` stays under ~3 s.

5. **Fix the latent fat64 parse and cover it (F5).** Correct `entryWidth`/`offset`/`size` for `FAT_MAGIC_64`, add a `uint64` reader, and add the two fat cases to `MachOContentHashTests`.
   *Accept:* a `FAT_MAGIC_64` container wrapping the thin fixture hashes identically to the thin image, including when the arm64 entry is second.

6. **Fix the VT argv leak (F6).** Feed the header on stdin (`-H @-`).
   *Accept:* the key does not appear in `ps` output during the run; the scan still completes.

7. **Stop claiming a disable that isn't persisted (F7).** Return failure (and let the menu offer Reconnect) when `disable()` is called with the daemon down.
   *Accept:* with the helper stopped, choosing **Disabled** does not report success; the daemon restarting does not leave the UI claiming Disabled.

8. **Heal a dropped wake event (F8).** Cross-check `currentSystemPowerState()` on the re-assert tick before trusting `isSleeping`.
   *Accept:* killing and reviving the daemon while awake never leaves the LED pinned off by a stale flag.

9. **Tidy the shell and CI smalls (F9, F12, F20, F11).** `wait_for_job_gone` returns 1 on timeout with documented call-site tolerance; fix the bot email; guard `apply-vt-proof.py`'s argv; pin action SHAs (+ Dependabot).
   *Accept:* `grep -rn magleep .github/` is empty; `bash -n` on the edited scripts passes; every `uses:` ends in a 40-hex ref.

10. **Close the small app-side gaps (F13, F14, F15, F16, F17, F21).** Async initial refresh; `queue.sync {}` on the error path; the two `activate()` replacements; gate the Night Schedule item; fix the README menu table (and AGENTS.md); add app-side `os.log`.
    *Accept:* `swiftlint --strict`, `lethen --strict`, `swift test`, and the warnings-as-errors build all stay green; the README table matches `createMenu()` item titles.

11. **Document the two honest limits (F10, F19).** Adjust the install-integrity claim to say "partial tampering", and the workflow comment to stop claiming reproducible bytes (or make B5 real).

12. **Then pick up the improvements**, starting with the quick wins (Q1–Q7) and treating B1/B2 as the structural investment that pays for itself the next time the install path regresses.

---

## 13. Remediation status (applied after this audit)

Everything above was written as a review-only pass. A follow-up pass then applied fixes for every defect in §5. This section records what actually changed, so the audit reads as a closed loop rather than a wish list.

### Defects — all 22 addressed

| ID | Outcome | Change |
|---|---|---|
| F1 | **Fixed** | `release.yml`: `VIRUSTOTAL_API_KEY` scoped to the VirusTotal step, `SPARKLE_EDDSA_KEY` to the two signing steps, `GH_TOKEN` to the two `gh` steps; the job-level `env:` block is gone |
| F2 | **Fixed** | `needsUpgrade` now drives the status icon (`arrow.down.circle`) and `statusTitle` ("Helper update available") |
| F3 | **Fixed** | `ARCHITECTURE.md`/`STRUCTURE.md` (and this report) are tracked; the Periphery→Lethen rename is committed |
| F4 | **Fixed** | `SocketServer` moved to `MagSleepCore`; `SocketFraming` + `PeerAuthorization` extracted as pure types; 15 new unit tests + a 4-test live integration suite |
| F5 | **Fixed** | Correct fat strides (20 / 32), 64-bit reads, overflow-free bounds check, new `uint64` reader; 4 new tests. See the corrected section in §6 |
| F6 | **Fixed** | VirusTotal headers sent via `curl -H @-` (stdin); verified locally against a header-capturing server |
| F7 | **Fixed** | `disable()` now fails when the daemon is unreachable instead of reporting success (the menu offers Reconnect) |
| F8 | **Fixed** | The 3 s watchdog cross-checks `currentSystemPowerState()` and clears a stale `isSleeping` |
| F9 | **Fixed** | `wait_for_job_gone` returns 1 on timeout; both call sites say so explicitly and keep proceeding |
| F10 | **Fixed (documentation)** | The install-helper comment states the limitation; `SECURITY.md` gains a security-model section with the same limit spelled out. The mechanism fix (a trust anchor outside the bundle) would need a Developer ID — explicitly out of scope per baseline #9 |
| F11 | **Fixed** | `actions/checkout`, `actions/attest` and `github/codeql-action` pinned to commit SHAs; `.github/dependabot.yml` added |
| F12 | **Fixed** | `magsleep[bot]` in both bot-author sites |
| F13 | **Fixed** | `HelperManager.init` loads local state then probes asynchronously (behaviour note in the CHANGELOG) |
| F14 | **Fixed** | `queue.sync {}` joins the drains on the launch-failure path |
| F15 | **Fixed** | `NSApp.activate()` / `existing.activate()`; the warnings-as-errors build is clean |
| F16 | **Fixed** | `nightScheduleItem.isEnabled = helper.isLoaded && helper.isEnabled`, kept current in `updateMenuStates()` |
| F17 | **Fixed** | README menu table gains Night Schedule and drops the ellipsis; `AGENTS.md` menu list updated |
| F18 | **Info → fixed** | README badge now reads "Swift 5.10" |
| F19 | **Fixed (comment)** | `build-app.sh` and `release.yml` now state that bytes are *not* reproducible and that provenance comes from the attestation. Making them reproducible is B5, deliberately not attempted |
| F20 | **Fixed** | `apply-vt-proof.py` validates `argv` and prints usage |
| F21 | **Fixed** | `os.log` added to `HelperManager` (script outcome + stderr + confirmation timeout) and `UpdateManager` (the lone `NSLog`) |
| F22 | **No change (by design)** | The 32-client cap + backlog 8 is informational; the report itself notes it is "not a vulnerability" and offers the idle-sweep interval as the only lever if it ever mattered. Nothing was silently dropped |

### One new defect found while fixing

| ID | Sev | Location | Finding |
|---|---|---|---|
| F23 | Low | `SECURITY.md:25` | The file ended **mid-sentence** ("Please include as much information as possible") — the reporting instructions were truncated and there was no threat model at all. Completed, and the F10 security-model section added |

### Verification of the remediation pass

| Check | Result |
|---|---|
| `swift test` | **115 tests, 0 failures** (was 95) — 7 framing, 5 peer-auth, 4 socket-server integration, 4 fat Mach-O |
| `swiftlint lint --strict` | clean |
| `lethen scan --strict` | clean |
| `swift build -c release --arch arm64 -Xswiftc -warnings-as-errors` | clean |
| `curl -H @-` behaviour | verified against a local header-capturing server before use |
| `fat_arch` / `fat_arch_64` sizes | verified against `<SDK>/usr/include/mach-o/fat.h` and the ABI |

### Improvements — deliberately NOT implemented

The §11 feature list (Q1–Q7, B1–B12) is **product work, not defect repair**, and the request was to fix the findings; none of it was silently dropped:

- **Q6 (pin action SHAs + Dependabot)** was absorbed into F11.
- **B1/B2 (testable helper lifecycle)** were *partially* done — the F4 extraction covers the socket boundary, which was the highest-value half. The install/update-decision extraction remains open.
- **Q1–Q5, Q7, B3–B12** (an "Update helper" menu item, richer AppleScript results, a `--status` one-shot, `make doctor`, an SBOM, battery-aware behaviour, log rotation, reproducible bytes, an ADR, a manual night window, and the SU-framework/config-portability items) are unimplemented. Each adds user-visible surface or new configuration, which this project's rules require asking about first.

---

## Closing

MagSleep is in good shape. The pure core is a model of how to make a two-process design testable, the privileged path is hardened well beyond its peers, and the release pipeline does the things that actually matter (CI-only builds, attestation, appcast key verification). The gaps I found are the *predictable* ones for a project at this stage: the complexity moved to the install/update lifecycle faster than the tests did (F4), a couple of comments describe the intent rather than the code (F2, F17, F19), and two security controls are applied with the right mechanism but the wrong scope (F1, F6). All four Mediums are hours of work, and the first three of them would have prevented or shortened at least three of the last six releases' worth of install-path firefighting.

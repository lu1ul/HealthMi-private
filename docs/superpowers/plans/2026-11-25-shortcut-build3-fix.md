# Shortcut Build 3 Compatibility Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. Keep changes in this conversation and make a local Git commit after each implementation stage.

**Goal:** Stop the iOS 16.3 App Intents runtime crash by removing dialog results and retry background scheduling when a shortcut reuses a queued run.

**Architecture:** Keep both intents lightweight and silent. They return only `some IntentResult` with `.result()`. Reused queued records are not duplicated; the Intent retries an immediate BGAppRefresh request when its handler is registered and logs whether scheduling was submitted, deferred, or failed. The existing 24-hour stale threshold remains because background execution is system scheduled.

**Tech Stack:** Swift 6, App Intents, BackgroundTasks, XcodeGen, GitHub Actions, `gh` CLI.

---

## Files and responsibilities

- Modify `HealthMi/App/SyncIntent.swift`: remove dialog result capabilities and resubmit queued work on reuse.
- Modify `project.yml`: set `CURRENT_PROJECT_VERSION` to `3` for an unambiguous device build.
- Modify `CHANGELOG.md`: describe the corrected silent result behavior and queued rescheduling.
- Modify `HealthMi项目代码全面审查报告.md`: add source changes, rationale, and evidence from the build.
- Modify `iOS16最低版本适配研究与实施记录.md`: record compatibility decisions and validation boundary.
- Modify `docs/superpowers/specs/2026-11-25-shortcut-return-and-discovery-fix-design.md`: mark this approved design implemented and correct the source-vs-IPA static-check description.

## Task 1: Remove dialog returns and retry a queued run

**Files:** Modify `HealthMi/App/SyncIntent.swift`.

- [x] Change both `perform()` signatures from `some IntentResult & ProvidesDialog` to `some IntentResult`.
- [x] Replace every `.result(dialog: IntentDialog(...))` with `.result()`; remove the dialog string variables and the private `queuedDialog` / `activeDialog` helpers.
- [x] Keep the existing error logging and `recordIntentReturn` events. Rename the error branch from `error_dialog` to `error_result` so logs reflect the new behavior.
- [x] In the existing active-run branch, resubmit only for `active.status == .queued`:

```swift
if active.status == .queued {
    do {
        let scheduled = try BackgroundSync.scheduleFromIntentIfRegistered(immediate: true)
        DiagnosticLogger.record(
            scheduled ? .info : .notice,
            category: .appIntent,
            event: "shortcut.sync.perform.queued_reschedule_attempted",
            message: scheduled
                ? "复用中的排队任务已重新提交后台调度请求"
                : "复用中的排队任务仍在队列中，当前进程未确认后台处理器注册",
            runID: active.id,
            metadata: invocation.metadata([
                "status": active.status.rawValue,
                "trigger": active.trigger.rawValue,
                "queueAgeSeconds": String(max(0, Int(Date().timeIntervalSince(active.queuedAt)))),
                "scheduledImmediately": String(scheduled),
            ])
        )
    } catch {
        DiagnosticLogger.record(
            .error,
            category: .appIntent,
            event: "shortcut.sync.perform.queued_reschedule_failed",
            message: "复用中的排队任务重新提交后台调度失败；保留原排队记录",
            runID: active.id,
            error: error,
            metadata: invocation.metadata([
                "status": active.status.rawValue,
                "queueAgeSeconds": String(max(0, Int(Date().timeIntervalSince(active.queuedAt)))),
            ])
        )
    }
}
```

- [x] Preserve the existing queued record on rescheduling error. Do not reschedule a `.running` record.
- [x] Leave `staleQueuedInterval` at 24 hours and preserve stale transition logging.
- [x] Run `rg -n "ProvidesDialog|result\\(dialog:|IntentDialog" "HealthMi/App/SyncIntent.swift"`; expected output is empty.
- [x] Run `git diff --check`; expected exit code is 0.
- [x] Commit as `fix: avoid shortcut dialog crash and retry queued sync`.

## Task 2: Mark the device build

**Files:** Modify `project.yml`.

- [ ] Change `CURRENT_PROJECT_VERSION: "2"` to `CURRENT_PROJECT_VERSION: "3"`; retain marketing version `1.1.0` and deployment target `16.0`.
- [ ] Check with `rg -n "CURRENT_PROJECT_VERSION|IPHONEOS_DEPLOYMENT_TARGET|MARKETING_VERSION" "project.yml"`; expected values are `3`, `16.0`, and `1.1.0`.
- [ ] Run `git diff --check` and commit as `build: bump shortcut compatibility build to 3`.

## Task 3: Record implementation decisions

**Files:** Modify the three project records listed above.

- [ ] Update the unreleased changelog: App Intents no longer produce dialogs; state lookup and detailed errors remain in app history, notifications, and diagnostic logs; queued reuse retries scheduling.
- [ ] Add a dated report section separating confirmed code facts from the remaining iOS 16.3 device runtime check.
- [ ] Add a dated iOS 16 compatibility entry with the reason for retaining the 24-hour queue expiration and the distinction between BGTask submission and handler start.
- [ ] Update the design status to implemented and state that source checks verify removal of dialog code while IPA inspection verifies build number, deployment target, actions metadata, and TrollStore entitlements.
- [ ] Run `git diff --check` and commit as `docs: record shortcut build 3 implementation`.

## Task 4: Build and inspect the GitHub artifact

**Files:** No workflow changes are planned; `.github/workflows/build-unsigned-ipa.yml` already builds unsigned and TrollStore HealthKit IPAs when the source or `project.yml` changes.

- [ ] Confirm `gh auth status` is authenticated as `lu1ul` and that the `personal` remote is `https://github.com/lu1ul/HealthMi-private.git`; never push to `origin`.
- [ ] Push the committed `main` branch only to `personal` to trigger the existing IPA workflow.
- [ ] Use `gh run list`, `gh run view`, and `gh run watch` to identify and wait for the workflow run; do not use the browser.
- [ ] Download both artifacts with `gh run download $runId --repo lu1ul/HealthMi-private --dir "build/shortcut-build-3"`; confirm that directory is Git-ignored before downloading.
- [ ] Inspect each IPA with Python `zipfile` and `plistlib`; verify `CFBundleVersion=3`, `CFBundleShortVersionString=1.1.0`, `MinimumOSVersion=16.0`, and both App Intent definitions. For the TrollStore package also verify HealthKit and Keychain entitlements as in the workflow report.
- [ ] Calculate SHA-256 for each downloaded IPA and append the run ID, artifact paths, hashes, and checks to the report and compatibility record.
- [ ] Commit those final evidence records as `docs: record shortcut build 3 IPA verification`.

## Validation boundary

The GitHub action confirms compilation and package structure. It cannot exercise the iOS 16.3 App Intents runtime or cause BGAppRefresh to run on the user's device. Final device acceptance requires installing build 3 through TrollStore, removing/re-adding the shortcut action, then checking that the fatal return-contract error is absent and the queued reschedule events appear in exported logs.


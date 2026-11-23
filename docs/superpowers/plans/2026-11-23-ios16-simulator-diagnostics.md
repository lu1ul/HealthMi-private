# iOS 16.4 Simulator Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the existing GitHub Actions startup diagnostic on an iOS 16.4 iPhone Simulator and keep the current newer-runtime diagnostic available.

**Architecture:** Extend the existing manual workflow with a runtime selector whose default is iOS 16.4. The iOS 16.4 path selects Xcode 16.4, downloads the matching Simulator runtime, selects an iPhone 14 device explicitly, and fails without falling back if the exact runtime is unavailable. Both runtime paths reuse the existing build, launch, log, crash report, and artifact collection steps.

**Tech Stack:** GitHub Actions YAML, Xcode 16.4, `xcodebuild`, `simctl`, Python 3 for simulator JSON selection.

---

### Task 1: Add an explicit iOS 16.4 simulator mode

**Files:**
- Modify: `.github/workflows/diagnose-simulator-startup.yml`

- [ ] **Step 1: Add a manual runtime selector**

Add this input beneath `on.workflow_dispatch`:

```yaml
    inputs:
      simulator_runtime:
        description: 'Simulator OS for startup diagnostics'
        required: true
        type: choice
        options:
          - ios-16.4
          - runner-default
        default: ios-16.4
```

Keep the workflow manual-only and preserve `permissions: contents: read`.

- [ ] **Step 2: Install the requested runtime and preserve download diagnostics**

Before simulator discovery, create `build/simulator-diagnostics/`. When `github.event.inputs.simulator_runtime` is `ios-16.4`, select Xcode 16.4 and run:

```bash
sudo xcode-select -s /Applications/Xcode_16.4.app/Contents/Developer
xcodebuild -version
xcodebuild -downloadPlatform iOS -buildVersion 16.4 2>&1 | tee build/simulator-diagnostics/runtime-download.log
xcrun simctl list runtimes available
```

If selection or download fails, let the job fail; the existing `if: always()` artifact step must still upload `runtime-download.log`. Increase the job timeout from 20 to 45 minutes to allow runtime download and simulator boot.

- [ ] **Step 3: Select only the requested runtime and device**

In the simulator selection step, read `xcrun simctl list devices available -j`. For `ios-16.4`, accept only devices under runtime identifier `com.apple.CoreSimulator.SimRuntime.iOS-16-4` and choose `iPhone 14`; exit with a clear error if that runtime or device is absent. Do not select a device under another runtime. For `runner-default`, preserve the existing available-iPhone selection behavior.

Write the selected device name, UDID, and runtime identifier into `$GITHUB_OUTPUT` and `metadata.txt` so the artifact proves which OS actually ran.

- [ ] **Step 4: Reuse the existing build and launch diagnostics**

Continue to build for the selected simulator UDID, install HealthMi, launch it, wait 20 seconds, check the app process, collect the unified log, screenshot, and any HealthMi crash report, then upload the artifact for 7 days. Keep the existing “fail if app did not remain running” result behavior.

- [ ] **Step 5: Review the workflow diff**

Run:

```bash
git diff --check
git diff -- .github/workflows/diagnose-simulator-startup.yml
```

Expected: no whitespace errors; runtime selection is explicit; iOS 16.4 cannot silently fall back; workflow permissions and artifact retention remain unchanged.

- [ ] **Step 6: Commit the workflow change locally**

```bash
git add .github/workflows/diagnose-simulator-startup.yml
git commit -m "ci: add iOS 16.4 simulator diagnostics"
```

### Task 2: Run and record the GitHub-hosted iOS 16.4 check

**Files:**
- Modify: `iPhone闪退与iOS模拟器诊断记录.md`

- [ ] **Step 1: Push the committed workflow to the private `personal` remote**

Push only to `personal` (`lu1ul/HealthMi-private`), never to `origin` (`ShawnDiego/HealthMi`). This push is needed to run the requested hosted workflow; retain all local commits.

- [ ] **Step 2: Dispatch the iOS 16.4 run**

Run the `Diagnose simulator startup` workflow with `simulator_runtime=ios-16.4`. Expected runtime evidence in the artifact: `com.apple.CoreSimulator.SimRuntime.iOS-16-4`, iPhone 14, and a successful build/install/launch.

- [ ] **Step 3: Record the observed result**

Update `iPhone闪退与iOS模拟器诊断记录.md` with the run URL/ID, selected Xcode/runtime/device, app process result after 20 seconds, and artifact contents. If runtime download fails, record its exact error and state clearly that no iOS 16 simulator launch was performed.

- [ ] **Step 4: Commit the diagnostic result locally**

```bash
git add "iPhone闪退与iOS模拟器诊断记录.md"
git commit -m "docs: record iOS 16.4 simulator run"
```

## Limits

This is an iOS 16.4 Simulator launch check, not a test of iOS 16.3, TrollStore signing, HealthKit permissions, HealthKit data, or background task scheduling on a physical iPhone. A successful simulator run does not rule out a device-specific crash in the user's installed IPA.

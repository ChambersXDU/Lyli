# Build performance assessment

Measured on 2026-09-30 on an arm64 Mac with 8 logical CPUs, using Apple Swift 6.2.4 and the Command Line Tools. These are local measurements, not CI timings or promises for other machines. Builds were run sequentially; the comparison includes assembling and signing a bundle with `--dest`, and excludes installing or restarting the app.

The main bottleneck is optimized Release compilation. Release uses whole-module optimization for both `LyliCore` (63 Swift files) and `lyli` (59 Swift files). A change inside an app helper function recompiles the app module. Debug uses incremental compilation and is the faster path for daily development.

## Measurements

| Scenario | Elapsed time | Interpretation |
| --- | ---: | --- |
| Original Release build, fresh scratch directory | 102.7 s | Includes initially empty compiler/package caches and all package products |
| Debug app-only build, fresh scratch directory | 72.1 s | A first build still compiles both modules and populates its caches; the configuration differs from the original Release measurement |
| Original Release bundle, unchanged source and existing artifacts | 1.53 s | Packaging and signing are a small part of the total |
| Debug bundle, unchanged source and existing artifacts | 1.44 s | A second unchanged build preserves the fast no-op path |
| Original Release bundle after one app helper edit, two runs | 22.91 / 21.83 s | Whole-module optimization dominates the edit cycle |
| App-only Release bundle after equivalent edits, two runs | 21.24 / 21.77 s | Narrowing the build target has a small effect; this difference alone is too small to establish a stable speedup |
| Debug bundle after equivalent edits, two runs | 3.01 / 2.39 s | Mean 2.70 s versus the original Release mean 22.37 s: about 8.3 times faster, or 88% less time |

The edit comparison inserted an unused local constant into the existing `NSColor.hexStringWithAlpha` getter in `AppearanceHelpers.swift`, using a different value for each build to invalidate its function body. The source was restored after measurement. Both configurations already had build artifacts, all bundles used the same version and signing path, and no instrumented compiler flags were enabled during this comparison. A larger UI edit or a public API change can rebuild more files, so the measured edit speedup should not be extrapolated to every change.

A separate Release compiler profile with warm module caches recorded the following frontend wall times. Rows are compiler stages; totals also include smaller stages that are omitted from the table.

| Frontend stage | LyliCore | App |
| --- | ---: | ---: |
| Type checking and semantic analysis | 1.41 s | 4.62 s |
| SIL optimization | 9.27 s | 12.40 s |
| SIL generation | 0.39 s | 1.29 s |
| IR generation | 0.39 s | 1.23 s |
| LLVM pipeline | 0.08 s | 0.13 s |
| Total frontend | 12.40 s | 21.20 s |

SIL optimization accounts for approximately 65% of the combined frontend time. The longest measured function body type check was `LyricsManagerView.body`, at 429 ms. The package already uses 8 jobs on this machine; increasing the job count or reorganizing SwiftUI expressions would not address the largest measured stage. Release optimization settings remain unchanged.

## Build changes

Use `./build.sh --debug` to build, install and start the app during development. It selects the standard SwiftPM Debug configuration and retains separate Debug and Release artifacts. The first Debug build still needs to compile its targets and populate caches; the fast edit timings require existing artifacts.

`./build.sh` continues to default to Release. `--configuration debug|release` allows explicit selection, and `package.sh` always passes `--configuration release`. Every installation build now selects `--product lyli`, so it does not build the standalone selftest runner. Selftests remain available through their existing commands.

The app bundle is assembled after compilation succeeds. A single architecture is copied directly to the bundle, and a universal build merges its slices directly there. This removes the extra binary copy and the uncollected temporary directory from the original script. Signing, architecture checks, atomic installation and restart behavior are retained.

Validation passed for Debug and Release arm64 bundles, including signing, architecture checks, installation and startup. A fresh Debug scratch build produced the app without a selftest binary, module or object files. Explicit configuration selection, invalid/missing arguments and a destination containing spaces were checked. The original Debug and Release selftests passed, as did all 20 lyrics workflow regression tests; Debug covered the QRC checks that the Release selftest skips. The installed app was finally restored to Release and its binary UUID matched the current Release build.

## Reproducing measurements

Run from the `lyli` directory. Use the same machine, architecture, signing identity and source change when comparing builds. Run each command separately, and retain `.build` for incremental measurements.

```sh
# Daily development: build and assemble a signed bundle without installing it.
/usr/bin/time -p ./build.sh --debug --dest /tmp/Lyli-debug.app

# Optimized Release: the default remains unchanged.
/usr/bin/time -p ./build.sh --configuration release --dest /tmp/Lyli-release.app

# Run again without editing to measure the unchanged-source path.
/usr/bin/time -p ./build.sh --debug --dest /tmp/Lyli-debug.app
```

Use a separate scratch directory for compiler profiling because changing compiler flags forces rebuilding. The statistics include compiler stage timers; the function body log identifies type-checking hotspots. Initial runs also include cold module cache costs, so warm the same directory before interpreting the compiler timers.

```sh
profile_dir="$(mktemp -d /tmp/lyli-profile.XXXXXX)"
mkdir -p "$profile_dir/stats"
LYLI_SPM_SCRATCH_PATH="$profile_dir/build" ./scripts/swiftpm.sh build \
  -c release --product lyli \
  -Xswiftc -Xfrontend -Xswiftc -stats-output-dir \
  -Xswiftc -Xfrontend -Xswiftc "$profile_dir/stats" \
  -Xswiftc -Xfrontend -Xswiftc -debug-time-function-bodies \
  > "$profile_dir/compiler.log" 2>&1
```

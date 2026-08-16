# Handoff: CI workflow refactor (audio.cpp fork)

**Branch:** `feat/refactor-workflow` (3 commits, pushed to `origin` = `xashr/audio.cpp`)
Also pushed as `ci/linux-workflow` (test branch — the repo's workflows trigger on `ci/**` pushes).
**Fork purpose:** this fork exists only to open a PR against upstream `0xShug0/audio.cpp`.
Only upstream branches matter for CI design: long-lived = `main` + `dev`; releases are **tags**
(`release-0.6` etc.), not branches. **Remove `wip/` from the branch before opening the upstream PR.**

## 1. Problem statement

The fork's CI (inherited from upstream, 5 workflows) is build-only and not future-proof:
- `linux-build.yml`: cpu+vulkan, gcc-13, **Debug**, 3 targets, no tests
- `mac-build.yml`: macos-14 (EOL), CPU-only, no Metal
- `windows-build.yml`: CPU-only (scripts support CUDA/HIP/Vulkan)
- `nix-build.yml`: 2 of 8 flake packages
- `docker.yml`: daily multi-arch publish (good, keep as-is)

Gaps: no ctest ever runs (a full CTest suite exists: `ENGINE_BUILD_TESTS=ON`, 50 tests),
no CUDA/HIP/Metal/Windows-GPU build coverage, no ccache, no concurrency groups, no path
filters, duplicated loader-sync check in 4 files, dead `release-0.2` branch trigger.

## 2. Target architecture (agreed plan)

Per-domain workflows (llama.cpp style) + TF-style hygiene. One job = one (OS, backend) tuple.

| Workflow | Contents | Status |
|---|---|---|
| `ci-linux.yml` | cpu x64 (build+ctest), cpu arm64 (build-only*), vulkan x64/arm64 (build-only), CUDA container (build-only, arch=89). *arm64 ctest + HIP job deferred, see Future Tasks (FT-1/FT-2) | ✅ **green** (run 31910114679) |
| `ci-macos.yml` | macos-latest arm64 (Metal ON) + macos-15-intel (Metal OFF), build+ctest, **OpenMP OFF** (AppleClang, gotcha #5), ccache gated (main/dev+PR only), -j4 cap | ❌→fix in flight (ed3d563, see §8) |
| `ci-windows.yml` | windows-2025: cpu (build+ctest) ✅, vulkan (pinned LunarG SDK, build-only) ✅, cuda (manual dispatch only: choco toolkit + build, llama.cpp precedent) — all via `scripts/build_windows.ps1` | ✅ green (cuda unverified, FT-6) |
| `ci-nix.yml` | cpu, vulkan, python-scripts (linux x64) + metal (macos-latest); nixpkgs pinned via flake.lock; cuda/rocm/rocm-gfx1151 deferred (FT-5) | ✅ **green** (all 4 jobs) |
| `ci-checks.yml` | fast: loader/catalog sync (deduped from the 4 old files) + actionlint on workflow YAML; ~30s, no path filter | ✅ green (31942542959) |
| `ci-webui.yml` | node 22: npm ci + svelte-check + vite build (`webui/native`, has `check` script) | TODO (phase 2) |
| `ci-docker.yml` | PR-only buildx build (no push) to validate Dockerfiles | TODO (phase 2) |
| `ci-sanitizers.yml` | ASan/TSan/UBSan matrix (PR-only) | TODO (phase 3, optional) |
| old `linux-build.yml` etc. | delete as replacements prove green | **ALL DELETED** (linux with its green run; mac/windows/nix on 2026-08-16 once cpu+vulkan/nix replacements were proven — user asked to stop them stealing runners) |
| `docker.yml` | keep as-is | — |

**Shared conventions (already in ci-linux.yml, copy to the rest):**
- triggers: `push: [main, dev, 'ci/**']`, `pull_request: [main, dev]`, `workflow_dispatch`
- path filters: `.github/workflows/<file>`, `**/CMakeLists.txt`, `**/.cmake`, `**/*.h|hpp|c|cpp|cu|cuh`, `model_specs/*.json` (CMake globs `model_specs/*.json`)
- `concurrency: group: ${{ github.workflow }}-${{ github.head_ref && github.ref || github.run_id }}`, `cancel-in-progress: true`
- top-level `permissions: contents: read`
- ccache: `ggml-org/ccache-action@v1.2.21`, key per os-backend, `evict-old-files: 1d`, `save: push && ref == refs/heads/main`
- Release builds, `-DENGINE_BUILD_TESTS=ON` in **every** job (all test sources compile against every backend)
- `timeout-minutes: 120`, `fail-fast: false`

**Key design decision:** ctest runs **only in CPU jobs**. GPU/Vulkan jobs are build-only
because several tests select their backend at compile time (`GGML_USE_CUDA`/`GGML_USE_VULKAN`,
e.g. `test_rnnoise_utility.cpp`) and require a real device, which GitHub runners/containers
don't have. This matches llama.cpp (no ctest in their CUDA container job).

## 3. Work achieved so far

Commits on `feat/refactor-workflow` (all pushed):
1. `0ec0be4` **fix(tests):** test suite was *never compiling* under `ENGINE_BUILD_TESTS=ON`:
   - 3 moss codec parity tools (`tests/moss_tts_local/codec_{encode,decode,dequant}_parity.cpp`)
     used a pre-`TensorSource` constructor API. Now open `--codec` file via
     `engine::assets::open_tensor_source(path[, "audio_tokenizer_weights"])`
     (GGUF gets the production prefix; safetensors plain). They are manual CLIs, **not ctest-registered**.
   - `scaled_dot_product_attention_test`: CUDA-only; now probes `init_backend({Cuda,...})`,
     catches, exits `125`; CMake: `SKIP_RETURN_CODE 125` + `TIMEOUT 300`
     (project's own pattern, cf. parakeet tests). `init_device_backend` throws on all failure modes.
   - `test_supertonic_vector_convnext_exp`: 5%-faster timing gate is machine-dependent
     (failed on the dev machine); parity checks stay unconditional, timing gate now opt-in
     via `AUDIOCPP_RUN_PERF_TESTS=1`.
2. `0fe8845` **ci:** new `.github/workflows/ci-linux.yml` (see §2)
3. `9f340b1` small header note (also the push that triggered CI, see quirk §5.1)

**Local validation (done before pushing):**
- CPU: `build-ci-test/` — Release, `ENGINE_BUILD_TESTS=ON` → build green, **ctest 50/50**
  (3 legitimate skips: SDPA [no CUDA build], 2× parakeet [need multi-GB weights])
- CUDA: `build-ci-cuda/` — Release, `-DCMAKE_CUDA_ARCHITECTURES=89`, `ENGINE_ENABLE_CUDA=ON`
  → build+link green. Test *runs* on this machine are meaningless: the RTX 5090's 32 GB is
  saturated by an invisible tenant process → all GPU-allocating tests OOM'd.
- YAML: actionlint v1.7.7 (at `/tmp/lint/actionlint`) — passes.

## 4. Current CI status (run 31907888528 on `ci/linux-workflow`, pushed ~20:52 UTC)

https://github.com/xashr/audio.cpp/actions/runs/31907888528

| Job | Result | Notes |
|---|---|---|
| cpu (x64) | ✅ success | includes full ctest |
| vulkan (x64) | ✅ success | |
| vulkan (arm64) | ✅ success | |
| cpu (arm64) | ❌ failure | ctest: 7 tests fail — real arm64 bug, see §6 |
| HIP/ROCm (x64) | ❌ failure | fails at **Build** step (Configure OK, container OK → compile error in HIP code with `rocm/dev-ubuntu-24.04:6.4.4` + `gfx1030`). Fallback: `rocm/dev-ubuntu-22.04:6.1.2` (llama.cpp's proven pin) |
| CUDA (x64) | ✅ success | container build + link OK (nvidia/cuda:12.6.2, arch 89) |

Job IDs: HIP 95068438156, vulkan-arm64 95068438157, cpu-x64 95068438163, vulkan-x64 95068438169,
CUDA 95068438173, cpu-arm64 95068438188.

**Resolution (2nd run):** per user decision (2026-08-15): neither failing area was covered by
the old main workflows (`linux-build.yml` = build-only cpu/vulkan, no ctest, no HIP), so they
never worked before CI existed → **deferred, not regressions**. `ci-linux.yml` was adjusted:
arm64 cpu job → build-only (TODO FT-1), HIP job removed (TODO FT-2). Expect the follow-up
run to be fully green; if so, delete `linux-build.yml` and move to `ci-macos.yml`.

**Log access:** unauthenticated API works for this public repo for run/job/step *status*
(`GET /repos/xashr/audio.cpp/actions/runs/<id>/jobs`, `/actions/jobs/<id>` includes per-step
conclusions), but **log download returns 403 without a token**. Ask the user to paste failure
output (they can see it in the UI).

## 5. Gotchas learned (important!)

1. **GitHub silently skips path-filtered workflows on a branch-creating push**
   (`before` = zero SHA → no diff → paths never match). Verified empirically: first push to a
   new branch ran only the 4 old (path-filter-free) workflows; a second push to the existing
   branch triggered `CI (linux)`. Consequence: new workflows with path filters activate from
   the 2nd push / first PR. Not a problem for the upstream PR (PR diff includes the workflow).
   Also disproved: workflows do NOT need to exist on the default branch to run for push events
   (nix-build ran though it's absent on the default branch `release-0.1`).
2. **`nvcc -arch=native` falls back to sm_75 on GPU-less machines** — the CMake else-branch
   (`CUDA_ARCHITECTURES native`) means the *published* Docker CUDA images are sm_75-only.
   See `wip/ci-bugs-found.md` #1.
3. Untracked local files `PR.md`, `docs/architecture/`, `tests/perf/benchmark_cpu_variants.py`
   are the user's work-in-progress — **never commit them** (already accidentally committed once;
   was reset+recommitted cleanly).
4. Default branch of the fork is `release-0.1`; irrelevant to the upstream PR; user offered to
   change it but it turned out not to matter (gotcha #1 was the real issue).
5. **New workflows must inherit the old workflows' toolchain workarounds** (bit us on the
   first macos/windows push, commit `cc7d073` fixed it):
   - macOS: AppleClang has **no OpenMP runtime** → `find_package(OpenMP REQUIRED)` fails.
     Old `mac-build.yml` worked around it with `-DENGINE_ENABLE_OPENMP=OFF -DGGML_OPENMP=OFF`
     → ci-macos.yml mirrors that.
   - Windows: **`cl` is NOT on PATH** in the default shell, but **MinGW's `cc` IS** → bare
     `cmake -G Ninja` auto-detects MinGW and MSVC-only flags (`/utf-8`) break it. The old
     `windows-build.yml` never hit this because it uses `scripts/build_windows.ps1`, which
     locates MSVC via vswhere and passes explicit compiler paths → ci-windows.yml uses the
     script too. Added a `-BuildTests` override param to the script for the ctest job.
   - Windows vulkan SDK: no choco package named `vulkansdk` exists. Install the pinned
     official LunarG installer (llama.cpp's approach); it lands in `C:\VulkanSDK\<ver>`
     which `build_windows.ps1`'s Find-VulkanRoot reads via VULKAN_SDK.
   - General lesson: when replacing an old workflow, diff its configure flags against the
     project's build scripts first — they encode hard-won toolchain workarounds.
6. **Log access**: `gh` IS authenticated now (account xashr, GH_TOKEN in env).
   - `gh run list/view --repo xashr/audio.cpp` works; `gh run view <id> --log` only for
     COMPLETED runs (in-progress: "logs will be available when it is complete").
   - Raw: `curl -H "Authorization: Bearer $(gh auth token)" \
     https://api.github.com/repos/xashr/audio.cpp/actions/jobs/<jobid>/logs`
   - **macOS job log blobs are systematically lost** (BlobNotFound on the jobs of BOTH
     macos runs so far, even after completion; windows logs work fine). For macOS jobs the
     user's Actions UI is the only live window — ask them for the last ~20 log lines.
   - Step-level `conclusion` via API always works and localizes failures well.
7. **`gh workflow run` (dispatch) 422s**: dispatch resolves the workflow from the DEFAULT
   branch (`release-0.1`), where the new workflows don't exist (and `main` doesn't have
   them either). User offered to change the default branch; deferred — re-triggering by
   pushing a change to the workflow file works and doubles as a path-filter test.
8. **`macos-latest` can flip OS versions** (GitHub re-points the label; hypothesis for the
   current build hang, see §8). For a small project, pinning `macos-15` is the
   reproducible choice (llama.cpp uses macos-latest and accepts that churn).

## 6. DEFERRED (FT-1): arm64 test failures — future task, no deep dive for now

cpu (arm64) ctest: **7 failures, all pass on x64** (same code/flags):
`audio_dsp_test`, `rnnoise_utility_test`, `flashsr_utility_test`, `zipenhancer_utility_test`,
`encoder_module_test`, `depthwise_conv1d_lowering_test`, `fun_asr_nano_sanm_probe`.

Only one failure detail is known so far (sanm_probe, pasted by user):
```
projection.self_attn_layer_norm: count=60, max_abs=1.19209e-06, max_rel=6.07147e-06, worst_index=58
residual.self_attn_layer_norm: count=40, max_abs=3.57628e-07, max_rel=8.1989e-07, worst_index=16
fun_asr_nano_sanm_probe failed: projection mismatch at 0: expected -0.532126, got -0.989789,
absolute error 0.457663, limit 0.000306
```
- **Not a FP-tolerance/FMA-contraction issue** — 0.46 error vs 3e-4 limit is a genuine
  computation difference. layer_norm sub-checks pass (1e-6); the linear/conv "projection" is off.
- All 7 are audio math tests (conv/linear/FFT paths). Tolerances in sanm_probe:
  `kCpuAbsoluteTolerance=2e-4`, `kRelativeTolerance=2e-4` (tests/fun_asr_nano/sanm_probe.cpp).
- Reference data: `tests/fun_asr_nano/sanm_reference.{bin,json}` + `reference_sanm.py`
  (dumped from Python/PyTorch, likely x86).
- Suspects:
  - audio.cpp's own FFT: `src/framework/audio/detail/speech_fft_internal.h` (FFTPACK-derived;
    ARM NEON `VLEN` specialization exists; first ~1600 lines read = scalar transform kernels,
    rest of file not reviewed)
  - vendored ggml NEON kernels: `external/ggml/src/ggml-cpu/simd-gemm.h`, `arch/arm/`,
    `quants.c`, `repack.cpp`
  - RULED OUT: KleidiAI (`GGML_CPU_KLEIDIAI` OFF by default, not enabled by audio.cpp CMake)
- Investigation path (for whoever picks up FT-1, in order):
  1. Get the other 6 tests' failure output from the user (UI) — do they all show the same
     "large error in linear/conv, norms fine" pattern?
  2. Reproduce on arm64: dev machine has no qemu/docker/sudo (checked). Options: user runs
     ctest on any arm64 box (e.g. an M-series Mac or the same CI job with a debug branch
     push), or iterate via `ci/**` branch pushes with targeted diagnostics.
  3. Bisect: force generic CPU kernels (ggml has a generic fallback path) or NEON-off build
     on arm64 → if green, it's a ggml NEON kernel bug; if still red, audio.cpp own code
     (FFT header or module lowerings).
  4. This is a **product bug** (published arm64 Docker images affected) → once root-caused,
     fix + regression test, re-enable `run_tests: true` on the arm64 cpu job, and file an
     upstream issue referencing it.

## 7. Future tasks (deferred by user decision 2026-08-15)

The user's rule: parts that were not in the old main workflows (never covered/working) are
skipped for now and logged here instead of being deep-dived in the CI refactor.

- **FT-1: arm64 ctest — 7 failing audio-math tests** (§6). Blocked: needs arm64 repro.
  Unblocks: `run_tests: true` on the arm64 cpu job in `ci-linux.yml`.
- **FT-2: HIP CI job** (bugs doc #6). Needs: build log from user (job UI), then try the
  `rocm/dev-ubuntu-22.04:6.1.2` pin or 6.4.4 flag fixes. Unblocks: re-adding the `hip` job
  to `ci-linux.yml` (removed for now; its exact former content is in git history, commit
  `0fe8845`).
- **FT-3: sm_75 Docker images** (bugs doc #1) — product issue, file upstream, out of scope
  for the CI refactor (CI itself uses an explicit arch).
- **FT-4: aarch64-linux nix cross-builds** — `nix build .#cpu --system aarch64-linux`
  etc. not covered by ci-nix.yml (referenced in that file's header).
- **FT-5: nix cuda/rocm/rocm-gfx1151 package coverage** — never in CI before (old
  nix-build.yml only did cpu+vulkan); the nixpkgs toolkit stacks are very heavy to
  build, and the 16-core runners we tried for them sat queued 12h+ (public-repo
  larger-runner pool flaky). Jobs removed from ci-nix.yml for now (TODO marker in
  the file); re-add with a proven runner strategy.
- **FT-6: windows cuda manual job verification** — the cuda job in ci-windows.yml is
  gated to workflow_dispatch (llama.cpp precedent: heavy). It has never actually run
  green yet: choco `cuda --version=12.9.0.576` install is unverified. Run it via the
  Actions UI (or API dispatch once the workflow is on a default branch) and confirm
  the build; fallback install = llama.cpp's NVIDIA redist-zip action pattern.

## 8. State + immediate next steps (updated 2026-08-16 ~11:00 UTC)

### Status board (branch `ci/linux-workflow`, tip 84796b1)

| Workflow | State |
|---|---|
| CI (linux) | ✅ green (run 31910114679, re-confirmed on 653ee10) |
| CI (windows) | ✅ green (run 31940775162 on 25b1d26: cpu+ctest, vulkan; cuda job correctly skipped on push) |
| CI (nix) | ✅ **green** (run 31940963702 on 406deb4: cpu, vulkan, python-scripts, metal) |
| CI (checks) | ✅ green (re-confirmed every push) |
| CI (macos) | metal ✅ green in 13 min (ed3d563 & 09e58a0); x64 ❌ supertonic >1800 s on Intel → now excluded there (slow_ci label, -LE on x64 only) |
| CI (linux) | ✅ green on ed3d563; ❌ on 09e58a0 (audio_dsp flake, not a timeout change — see bugs #13) → tolerances fixed, 0/300 local |
| CI (windows) | ✅ green (09e58a0) |
| CI (nix) | ✅ green (09e58a0) |

### RESOLVED (pending green run): CI (macos) build failure = runner process-limit exhaustion

Run 31940963758 metal (arm64) job (user-pasted log tail):
`clang++: error: unable to execute command: posix_spawn failed: Resource temporarily
unavailable` → **EAGAIN: the runner user's process (and/or FD) limit was exhausted**
while make fanned out uncapped `--parallel` (= CPU count) × `make→ccache→clang→cc1`
process trees. Flaky/load-dependent (yesterday's identical build squeaked through at
46 min; today's died in the Build step). The "hang" impression was the macOS log stream
stalling (gotcha #6) — the job was failing, not stuck.

Fix pushed (**ed3d563**):
- Build step: `cmake --build build --parallel 4` (was uncapped) + `ulimit -n 10240`
  + diagnostics printed (`ulimit -a`, `kern.maxproc`, `kern.maxprocperuid`,
  `ps -A | wc -l`) → if it recurs, the log shows the actual limits to re-tune.
- Per-job timeouts: metal 240, x64 300 min (headroom for the slower capped builds).
- **ccache step gated** to contexts where a warm cache can exist
  (push main/dev + PRs; see `if:` in ci-macos.yml / ci-linux.yml). Rationale:
  - ccache = compiler cache (hashes TU+flags, reuses .o); the action uploads/downloads
    it via the GitHub per-repo cache. `save:` only on main pushes.
  - On ci/** test-branch runs the cache can NEVER be warm → pure overhead, and the
    extra per-compile process fan-out (ccache stays alive around each clang) aggravated
    the EAGAIN failure. Skipped on test pushes; active again on main/dev + PRs where it
    is worth 3-6× on PR builds (esp. macOS).
  - Note: the ci/** push that triggered the fix run also re-runs CI (linux) as a control
    (same build, ccache step now skipped) — expect green.

### ed3d563 results (run 31943639350, 2026-08-16 ~11:40 UTC)

- **metal (arm64): ✅ GREEN in 13 min** (build+ctest) — the -j4 cap + no ccache worked;
  also much faster than the 46-min runs, so those were inflated by EAGAIN thrashing
  and/or a slower macos-latest image than today's.
- **cpu (x64): ❌ Build OK (~11 min), ctest 49/50** —
  `supertonic_vector_convnext_exp_test ***Timeout 600.04 sec`. Root cause: real model
  inference runs **single-threaded on macOS** (OpenMP off for AppleClang) → >10 min on
  the Intel runner; fits in 600 s on linux (4 OpenMP threads). NOT a code bug.
  (Intel x64 build is ~11 min, not the 80 min estimated earlier — the "stuck at 77%"
  run was EAGAIN-stalled, not representative.)
- **CI (linux) re-run: ✅ all green** (control: ccache step skipped on ci/** pushes).
- Fix **09e58a0**: per-test `TIMEOUT` in the top-level CMakeLists (600 s default loop
  preserving existing 120/180/300/60 s; 1800 s for supertonic) + removed the global
  `ctest --timeout 600` from all 3 workflows (it would override per-test values).
  Verified locally: all 50 tests carry an explicit TIMEOUT in CTestTestfile.cmake.

### 09e58a0 results + the two follow-up fixes (pushed as 2 commits → tip 8dff9e4)

- **CI (macos) x64**: supertonic **timed out at 1800.04 s** — it needs >30 min
  single-threaded on the Intel runner → skipping is mandatory, not economics.
- **CI (linux) cpu (x64)**: `audio_dsp_test` FAILED — `istft_variant_parity`
  mean_diff 2.125e-6 vs 2e-6 tolerance. Root cause (bugs #13): that sub-check uses
  `WaveformMode::PerRun` (time-seeded random input) with tolerances sitting AT the
  float32 noise floor → 22/300 local runs failed (max_diff peaks ~2.2e-5 > old 2e-5
  max). Unrelated to the CMake timeout change.
- Fixes pushed (tip **8dff9e4**):
  - `tests/unittests/test_audio_dsp.cpp`: istft parity tolerances → **max 5e-5 / mean
    5e-6** (measured noise floor + margin; real bugs are O(≥1e-3)). **0/300 local.**
  - `CMakeLists.txt`: supertonic test gets `LABELS "slow_ci"` (keeps `TIMEOUT 1800`).
  - `ci-macos.yml`: matrix field `ctest_args` ("" metal / `"-LE slow_ci"` x64) → the
    slow test runs on linux/windows/metal, is excluded only on the scarce Intel x64 job.
    Verified: `ctest -LE slow_ci` = 49 tests, `-L slow_ci` = 1.

Next steps:
1. Watch the 8dff9e4 runs (linux/macos/windows/nix re-triggered via CMakeLists path
   filter): expect **all green for the first time across the board** — x64 job is now
   ~11 min build + ~10 min ctest (no supertonic). metal ~13 min. If audio_dsp flakes
   again at 5e-5/5e-6 (shouldn't — 0/300 local), next lever: ctest `RETRY_COUNT 1`.
2. Once all 5 workflows green → **phase 2**: ci-webui.yml (SvelteKit in webui/native:
   npm ci + svelte-check + vite build), ci-docker.yml (PR-only buildx build of the
   Dockerfiles).
3. Manual once: run the windows **cuda dispatch job** from the UI (FT-6; choco cuda
   12.9.0.576 install unverified).
4. If EAGAIN ever recurs at -j4: the printed `ulimit -a`/`kern.maxproc*` lines show
   the headroom → drop to -j2.

### Done since the 22:30 note (2026-08-16)
- 653ee10 results: linux ✅; windows cpu ✅ (the 8.3-path test fix works) + vulkan ✅
  (LunarG SDK install works) + cuda ❌ → **windows-2025 image has NO CUDA toolkit**
  (bugs doc #8); 25b1d26: cuda job split out + workflow_dispatch-gated + choco install
  (llama.cpp's build-cuda-windows.yml is the precedent: manual-only, "very heavy on the
  CI").
- 406deb4: ci-nix rescoped (dropped cuda/rocm/rocm-gfx1151 → FT-5; 16-core runners sat
  queued 12h+ — public-repo larger-runner pool is flaky) → **CI (nix) fully green
  including nix metal on macos-latest** (note: the nix metal job built fine on
  macos-latest TODAY while ci-macos hangs — more evidence the hang is ci-macos-specific,
  e.g. ccache or the plain-cmake build path, not the OS image).
- d5640cf: **deleted all old build workflows** (mac-build, windows-build, nix-build;
  linux-build already gone) per user request (they stole runners on every ci/** push);
  their unique coverage — the loader/catalog sync check — moved into new
  **ci-checks.yml** (sync check + actionlint, ~30s, no path filter).
- CI (checks) 31941161265 ❌: `actionlint .github/workflows/` → "is a directory" (needs
  a file glob; the sync check itself PASSED). Fixed in 84796b1 (`*.yml`).
- Environment: workspace moved (repo now back at /workspace/audio.cpp-fork,
  llama.cpp at /workspace/llama.cpp); /tmp was wiped (actionlint re-downloaded to
  /tmp/lint/actionlint — curl the v1.7.7 release tarball if gone again);
  **gh is authenticated** (gotcha #6).

### Then
- Phase 2: ci-webui.yml (SvelteKit: npm ci + svelte-check + vite build in webui/native),
  ci-docker.yml (PR-only buildx build to validate Dockerfiles).
- Phase 3 (optional): ci-sanitizers (ASan/TSan/UBSan, PR-only), code-style/clang-format,
  SHA-pin actions, tag-triggered release.yml.
- Before the upstream PR: drop `wip/`; decide required checks with maintainers
  (suggest: CI (linux) cpu + CI (checks) required; GPU jobs non-required); mention in
  the PR: new test coverage surfaced real bugs (wip/ci-bugs-found.md #1 sm_75 docker,
  #5 arm64 audio math) — the FT list is the follow-up plan.

## 9. Environment facts (dev machine)

- Repo at `/workspace/audio.cpp-fork`; `origin`=`xashr/audio.cpp` (SSH push works),
  `upstream`=`0xShug0/audio.cpp`
- 24-core x86_64, gcc 15.2, cmake 4.2.3, CUDA 13.3 toolkit + RTX 5090 (GPU memory occupied
  by invisible tenant — don't trust CUDA test *runs* here; builds are fine)
- No docker, no sudo, no qemu. `gh` CLI **is installed and authenticated** (gotcha #6).
  Network OK.
- Local build dirs (gitignored): `build-ci-test/` (CPU green), `build-ci-cuda/` (CUDA green)

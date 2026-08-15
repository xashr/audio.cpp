# Bugs found while refactoring CI

Found during the CI workflow work on `feat/refactor-workflow` (Aug 2026).
Items marked **[FIXED in branch]** are already handled on the branch; the rest are open.

---

## 1. Published Docker CUDA images are effectively sm_75-only  [OPEN — product bug]

**Symptom:** the daily Docker workflow builds `full-cuda12`/`full-cuda13` images on GPU-less
GitHub runners. `.devops/cuda.Dockerfile` passes no `CMAKE_CUDA_ARCHITECTURES`, so
`CMakeLists.txt` (line ~1335) falls into the `else()` branch:
`set_target_properties(engine_runtime PROPERTIES CUDA_ARCHITECTURES native)`.

**Verified behavior** (local, CMake 4.2.3 + nvcc 13.3):
- `nvcc -arch=native` with a GPU present → compiles for that GPU (sm_120 on RTX 5090)
- `nvcc -arch=native` with no GPU (`CUDA_VISIBLE_DEVICES=`) →
  `nvcc warning : Cannot find valid GPU for '-arch=native', default arch is used` → **sm_75**
- CMake cache shows `CMAKE_CUDA_ARCHITECTURES:STRING=75`; the compile line is `-arch=native`

So every published CUDA image contains **only sm_75 SASS** — no PTX, no newer archs.
Modern cards (Ampere sm_80+, Hopper sm_90, Blackwell sm_120) may fail to run it (SASS forward
compatibility is limited; Blackwell in particular dropped older SASS).

**Fix options:**
- explicit arch list in the Dockerfile, e.g. `-DCMAKE_CUDA_ARCHITECTURES="75;80;86;89;120-real"`
  (or narrower per CUDA version), and/or
- change the CMake `else()` default from `native` to a sensible fixed list (native is only
  meaningful on a dev machine that has the GPU it will run on — but for *shipping* images it's
  silently wrong).
- The CI job (`ci-linux.yml` CUDA) intentionally uses explicit `-DCMAKE_CUDA_ARCHITECTURES=89`
  (fast, deterministic, compile-verification only).

**Action:** file upstream issue (affects all published cuda12/cuda13 images, including
`full-cuda12-YYYYMMDD-*` immutable tags).

---

## 2. Test suite did not compile under `ENGINE_BUILD_TESTS=ON`  [FIXED in branch, 0ec0be4]

CI never built the tests, so this was invisible. Three manual parity CLIs in
`tests/moss_tts_local/` were committed (in upstream "Release 0.3" commit 66d233b) against a
`MossAudioTokenizer*` constructor API that no longer exists — the classes were refactored to
take `const assets::TensorSource &` in the same commit the tests were added.

Fixed by opening `--codec` via `engine::assets::open_tensor_source(path)`
(`.gguf` → with production prefix `"audio_tokenizer_weights"`, matching
`resource_bundle` GGUF handling; `.safetensors` → plain).

---

## 3. `scaled_dot_product_attention_test` failed on any non-CUDA build  [FIXED in branch, 0ec0be4]

Test unconditionally initializes a CUDA backend; on CPU builds it hard-failed
("CUDA backend requested but it is not registered in this build").
Now it probes availability first and exits 125 → registered in CMake with
`SKIP_RETURN_CODE 125` (project's existing skip pattern, cf. parakeet tests).

---

## 4. `supertonic_vector_convnext_exp_test` timing gate is machine-dependent  [FIXED in branch, 0ec0be4]

The test gates on the "exp" graph being ≥5% faster than the original. On the dev machine
(Intel Ultra 7 270K) the exp variant was actually **slower** (2.92 vs 2.23 ms mean) → hard
failure. The workload is tiny (96 frames × 256 ch); timing noise dominates.
Numerical parity checks (the valuable part) are now unconditional; the timing gate requires
`AUDIOCPP_RUN_PERF_TESTS=1`.

---

## 5. 7 ctest failures on arm64 — genuine computation differences  [OPEN — product bug]

CPU CI job on `ubuntu-24.04-arm`: 7 tests fail that pass identically on x64:
`audio_dsp_test`, `rnnoise_utility_test`, `flashsr_utility_test`, `zipenhancer_utility_test`,
`encoder_module_test`, `depthwise_conv1d_lowering_test`, `fun_asr_nano_sanm_probe`.

Only detail captured so far (sanm_probe):
```
projection mismatch at 0: expected -0.532126, got -0.989789, absolute error 0.457663, limit 0.000306
```
- Error magnitude (0.46) rules out FP-contraction/ULP tolerance effects — something computes
  a genuinely different value on arm64 (linear/conv paths; layer_norm sub-checks pass at 1e-6).
- Suspects: audio.cpp's own FFT (`src/framework/audio/detail/speech_fft_internal.h`) and/or
  vendored ggml NEON kernels (`external/ggml/src/ggml-cpu/simd-gemm.h`, `arch/arm/`).
  KleidiAI ruled out (OFF by default).
- Affects shipped arm64 artifacts (Docker cpu image arm64, nix aarch64 packages).
- Investigation state + next steps: `wip/ci-workflow-handoff.md` §6.

---

## 6. HIP build fails with `rocm/dev-ubuntu-24.04:6.4.4` in CI  [OPEN]

`ci-linux.yml` HIP job: container init + deps + **Configure all succeed**, Build step fails
(compilation error in the HIP code path; exact error not yet captured — job logs need a token,
ask the user for the UI output).
- Fallback: llama.cpp's proven pin `rocm/dev-ubuntu-22.04:6.1.2` (works on ubuntu-22.04
  runner; container image is runner-agnostic).
- Possibly a newer-ROCm vs vendored-ggml issue (6.4 vs 6.1), or a missing package
  (llama.cpp installs `rocblas-dev hipblas-dev rocwmma-dev` — we mirror that).

---

## 7. GitHub silently skips path-filtered workflows on branch-creating pushes  [process note]

Pushing a brand-new branch with a workflow that has `on.push.paths` → no run at all
(no error, no "skipped" run in the UI list). `before` is a zero SHA, so there's no file diff
to match paths against. Verified empirically (2026-08-15): first push to `ci/linux-workflow`
ran only the 4 legacy workflows; second push to the same branch triggered the new
path-filtered workflow.
- Workaround: 2nd push, or open a PR (PR diffs always include the changed files).
- Also verified: workflow files do NOT need to exist on the default branch for push events
  (a workflow only present on the pushed branch ran fine).

---

## 8. CI never covered GPU backends → silent bit-rot  [process note]

Pre-refactor CI built cpu/vulkan only. CUDA/HIP/Metal/Windows-GPU code paths had zero build
verification (they only compiled when Docker builds happened to pass). The new
`ci-linux.yml` compiles **all** sources (including tests) for CUDA and HIP — this is what
surfaced items #2/#6-class issues.

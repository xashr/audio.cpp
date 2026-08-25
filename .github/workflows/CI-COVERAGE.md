# CI Coverage — backend × platform (native builds)

Overview of what the per-domain CI workflows (`ci-linux`, `ci-macos`, `ci-windows`,
`ci-nix`) actually build and test. Docker image validation (`ci-docker`) and
non-build checks (`ci-checks`) are excluded here.

Keep in sync with the workflow files when matrices change.

## Coverage matrix

| **Backend \ Platform** | Linux (x64) | Linux (arm64) | macOS (arm64) | Windows (x64) |
|---|---|---|---|---|
| **CPU** (no GPU) | ✅ / ✅ | ✅ / ❌ ① | ✅ / ✅ | ✅ / ✅ |
| **Vulkan** | ✅ / ➖ ² | ✅ / ➖ ² | ➖ / ➖ ³ | ✅ / ➖ ² |
| **CUDA** | ✅ / ➖ ² | ❌ / ➖ ⁴ | ➖ / ➖ | ⚠️ / ➖ ⁵ |
| **Metal** | ➖ / ➖ | ➖ / ➖ | ✅ / ✅ | ➖ / ➖ |
| **ROCm / HIP** | ❌ / ➖ ② | ➖ / ➖ | ➖ / ➖ | ➖ / ➖ |

*Each cell: **build / test***

**Legend**
- ✅ — covered in CI
- ⚠️ — covered only via manual `workflow_dispatch` trigger, never executed yet
- ❌ — **gap**: supported, but not covered (details below)
- ➖ — not applicable: for *build* = combination not supported / not a project target; for *test* = structurally impossible on hosted runners (no GPU device; these tests bind their backend at compile time) → build-only by design, not a gap

**Gap details**
- ① Linux (arm64) CPU test — build green; ctest deferred: 7 audio-math test failures (product bug, **FT-1**)
- ② ROCm / HIP build — nixpkgs rocm 6.4.4 build failure (**FT-2**)
- ³ Vulkan on macOS — not a project target (ggml could, audio.cpp/llama.cpp don't)
- ⁴ CUDA on Linux (arm64) build — supported (arm64 CUDA Docker images published daily) but no native CI job; low priority
- ⁵ Windows (x64) CUDA build — dispatch-only; `choco cuda 12.9.0` install path unverified (**FT-6**)

**Notes**
- Test coverage = full 58-test ctest suite
- Every covered cell in Linux (x64) CPU/Vulkan and macOS (arm64) Metal additionally has a second-toolchain build via CI (nix) — nixpkgs gcc/clang, RelWithDebInfo, and the only CI compile of `LLAMAFILE` + native model manager
- Windows (arm64) omitted — no stable public-repo runner

## Where each variant is covered

| Variant | Workflow / job |
|---|---|
| Linux (x64) CPU, build + ctest | CI (linux) — `cpu (x64)` |
| Linux (arm64) CPU, build | CI (linux) — `cpu (arm64)` |
| Linux (x64/arm64) Vulkan, build | CI (linux) — `vulkan (x64/arm64)` |
| Linux (x64) CUDA 12.6, sm_89, build | CI (linux) — `CUDA (x64)` (`nvidia/cuda:12.6.2-devel-ubuntu24.04` container) |
| macOS (arm64) Metal, build + ctest | CI (macos) — `metal (arm64)` |
| Windows (x64) CPU, build + ctest | CI (windows) — `cpu (x64)` (MSVC via `scripts/build_windows.ps1`) |
| Windows (x64) Vulkan, build | CI (windows) — `vulkan (x64)` (pinned LunarG SDK) |
| Windows (x64) CUDA 12.9, sm_89, build | CI (windows) — `cuda (x64)` (dispatch-only) |
| Linux (x64) CPU/Vulkan + macOS (arm64) Metal, second toolchain | CI (nix) — nixpkgs derivations `.#cpu`, `.#vulkan`, `.#metal` (+ `.#python-scripts`) |

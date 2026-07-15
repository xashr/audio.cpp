# OuteTTS validation

This procedure exercises OuteTTS 1.0 1B in one long-lived audio.cpp session.
It covers normal TTS, framework long-form text chunking, voice cloning, repeated
reference-profile cache hits, cached-step graph reuse, stage timings, and
default-versus-`mem_saver` memory behavior.

## Model setup

Install the safetensors model, IBM DAC, and Qwen3 Forced Aligner resources:

```bash
python tools/model_manager.py install outetts_1_0_1b --models-dir models
```

The model-manager package id is `outetts_1_0_1b`. It creates these model
roots:

- `models/Llama-OuteTTS-1.0-1B`
- `models/DAC.speech.v1.0`
- `models/Qwen3-ForcedAligner-0.6B`

The standalone GGUF command is documented in [TTS](tts.md#outetts). The packed
file used below contains the OuteTTS language model, IBM DAC, Qwen aligner,
tokenizers, configuration, and package specification.

## Python reference setup

The maintainer can install the official OuteTTS reference without using any
audio.cpp conversion code:

```bash
python -m venv .venv-outetts
. .venv-outetts/bin/activate
python -m pip install --upgrade pip outetts
```

On Windows PowerShell with the optional CUDA llama.cpp backend:

```powershell
python -m venv .venv-outetts
.\.venv-outetts\Scripts\Activate.ps1
$env:CMAKE_ARGS = "-DGGML_CUDA=on"
python -m pip install --upgrade pip outetts
```

Select `outetts.Backend.HF` for a Transformers comparison or
`outetts.Backend.LLAMACPP` for the official llama.cpp-backed route. Use
`outetts.Models.VERSION_1_0_SIZE_1B`, temperature `0.4`, repetition penalty
`1.1` over the latest 64 tokens, top-k `40`, top-p `0.9`, and min-p
`0.05`.

## Exact build commands

The Windows validation used the project build script to establish the compiler
and backend configuration, then explicitly enabled the warm-benchmark targets.

Windows CPU:

```powershell
.\scripts\build_windows.ps1 -Preset windows-cpu-release -ConfigureOnly
cmake -S . -B build\windows-cpu-release -DENGINE_BUILD_WARMBENCH=ON
cmake --build build\windows-cpu-release --parallel 4 --target audiocpp_cli audiocpp_server outetts_warm_bench
```

Windows CUDA 12.4:

```powershell
$env:CUDA_PATH = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.4"
.\scripts\build_windows.ps1 -Preset windows-cuda-release -ConfigureOnly
cmake -S . -B build\windows-cuda-release -DENGINE_BUILD_WARMBENCH=ON
cmake --build build\windows-cuda-release --parallel 4 --target audiocpp_cli audiocpp_server outetts_warm_bench
```

## Exact standalone-GGUF path tests

The tested GGUF was deliberately outside the PR worktree and its directory
contained only one file:

```text
..\models\Llama-OuteTTS-1.0-1B_Q8\Llama-OuteTTS-1.0-1B_Q8.gguf
```

Normal TTS:

```powershell
build\windows-cuda-release\bin\audiocpp_cli.exe `
  --task tts --family outetts `
  --model ..\models\Llama-OuteTTS-1.0-1B_Q8\Llama-OuteTTS-1.0-1B_Q8.gguf `
  --backend cuda `
  --text "This is the standalone GGUF path test." `
  --max-tokens 256 --request-option seed=1234 `
  --out ..\outputs\outetts_path_test_tts.wav
```

Voice cloning using the aligner and DAC embedded in the same GGUF:

```powershell
build\windows-cuda-release\bin\audiocpp_cli.exe `
  --task clon --family outetts `
  --model ..\models\Llama-OuteTTS-1.0-1B_Q8\Llama-OuteTTS-1.0-1B_Q8.gguf `
  --backend cuda `
  --voice-ref assets\resources\b.wav `
  --reference-text "Some call me nature. Others call me Mother Nature. I've been here for over 4.5 billion years. 22,500 times longer than you." `
  --request-option reference_language=en `
  --text "This is the standalone GGUF cloning path test." `
  --max-tokens 256 --request-option seed=42 `
  --out ..\outputs\outetts_path_test_clone.wav
```

Both commands loaded successfully without an external package spec, tokenizer,
DAC directory, aligner directory, or other sidecar. The generated 24 kHz mono
WAVs passed ffmpeg decoding:

| Artifact | Duration | Bytes | SHA-256 |
|---|---:|---:|---|
| `..\outputs\outetts_path_test_tts.wav` | 1.399667s | 67228 | `92DA5D8438D4E6A79FBDDBD8EDA77D1AFD2A9B47F61085ECD3AD45C913102904` |
| `..\outputs\outetts_path_test_clone.wav` | 1.453000s | 69788 | `E5B46E62C2DB89A654F7EC21A7BE31F575D6F667F8578224386E7C552492B05E` |

## Exact long-lived-session runs

CUDA default:

```powershell
build\windows-cuda-release\bin\outetts_warm_bench.exe `
  --model ..\models\Llama-OuteTTS-1.0-1B_Q8\Llama-OuteTTS-1.0-1B_Q8.gguf `
  --backend cuda --threads 8 `
  --request-file tests\outetts\warm_bench_requests.json `
  --hold-seconds 5 `
  --audio-out-dir ..\outputs\outetts_review_cuda_default `
  --log-file build\logs\warmbench\outetts-cuda-default.log
```

Expected trace evidence:

- `outetts.text_chunk_count` is greater than one for `tts_longform`.
- `outetts.llama.step.graph_reused=1` appears after the first compatible
  generation request or chunk.
- the second identical reference reports `outetts.reference_cache.hit=1`.
- `tts_cold` and `tts_repeat` are byte-identical, as are `clone_cold`
  and `clone_repeat`; this verifies that warm graph/profile reuse does not
  change deterministic output.
- `outetts.aligner.runtime_reused=1` is observable for uncached references
  while the default session retains the aligner.
- only one active OuteTTS Llama runtime is retained; switching between native
  TTS weights and the CUDA F32 cloning fallback replaces the previous runtime.

Run the same request sequence in a fresh process with memory saver enabled:

```powershell
build\windows-cuda-release\bin\outetts_warm_bench.exe `
  --model ..\models\Llama-OuteTTS-1.0-1B_Q8\Llama-OuteTTS-1.0-1B_Q8.gguf `
  --backend cuda --threads 8 `
  --request-file tests\outetts\warm_bench_requests.json `
  --session-option outetts.mem_saver=true `
  --hold-seconds 5 `
  --audio-out-dir ..\outputs\outetts_review_cuda_mem_saver `
  --log-file build\logs\warmbench\outetts-cuda-mem_saver.log
```

CPU default:

```powershell
build\windows-cpu-release\bin\outetts_warm_bench.exe `
  --model ..\models\Llama-OuteTTS-1.0-1B_Q8\Llama-OuteTTS-1.0-1B_Q8.gguf `
  --backend cpu --threads 8 `
  --request-file tests\outetts\warm_bench_requests.json `
  --hold-seconds 5 `
  --audio-out-dir ..\outputs\outetts_review_cpu_default `
  --log-file build\logs\warmbench\outetts-cpu-default-final.log
```

The memory-saver trace reports a positive
`outetts.llama.step.released_cache_capacity` after generation and
`outetts.aligner.runtime_released=1` after an uncached reference.

Sample total-device VRAM every 250 ms while each fresh benchmark runs. Ensure
that no unrelated CUDA workload is active:

```powershell
nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -lms 250
```

Compare peak and final resident VRAM, request wall time, output duration, and RTF
between the two runs. Keep model, backend, device, seed, requests, and
quantization identical.

## Generated artifacts

Each benchmark directory contains:

```text
tts_cold_1.wav
tts_repeat_1.wav
tts_longform_1.wav
clone_cold_1.wav
clone_repeat_1.wav
```

The exact generated directories and logs were:

- `..\outputs\outetts_review_cuda_default`
- `..\outputs\outetts_review_cuda_mem_saver`
- `..\outputs\outetts_review_cpu_default`
- `build\logs\warmbench\outetts-cuda-default.log`
- `build\logs\warmbench\outetts-cuda-mem_saver.log`
- `build\logs\warmbench\outetts-cpu-default-final.log`

These validation artifacts are reproducible local outputs and are not committed
to the repository.

## Measured validation

The committed five-request sequence was measured with the packed Q8 GGUF on an
NVIDIA GeForce RTX 3090 (CUDA 12.4). VRAM was sampled every 250 ms from total
device usage with no other CUDA workload. Resident VRAM was sampled during the
five-second hold after all requests completed. CPU process working set was
sampled every 250 ms over the same request sequence and hold.

| Backend | Mode | Sequence wall | Audio | RTF | Peak memory | Resident memory |
|---|---|---:|---:|---:|---:|---:|
| CUDA | default | 33342.24 ms | 11.424s | 2.918 | 17653 MiB VRAM | 294 MiB VRAM |
| CUDA | `outetts.mem_saver=true` | 30990.93 ms | 11.424s | 2.712 | 5780 MiB VRAM | 294 MiB VRAM |
| CPU | default | 103526.0 ms | 11.49067s | 9.009 | 14573.3 MiB RSS | 6458.0 MiB RSS |

Both CUDA modes produced the same SHA-256 for the cold and repeated TTS pair and
for the cold and repeated clone pair. All ten CUDA and all five CPU generated
WAV files passed an ffmpeg decode check. The traces confirmed four framework
chunks for the long-form request, compatible step-graph reuse in default mode,
explicit graph release in memory-saver mode, and a reference-profile cache hit
on the repeated clone.

Generation is the dominant measured hot path. In the default CUDA run, the cold
reference path took about 890 ms (109 ms alignment, 139 ms DAC encoding, and
214 ms profile construction), while the repeated cached reference took 0.29 ms.
The memory-saver result is within normal run-to-run timing variation; its
purpose here is the lower peak, not a speedup guarantee.

## Path and parity results

- The standalone path test loaded the one-file GGUF from outside the worktree;
  no adjacent sidecars or `model_specs` directory were present.
- Within CUDA, cold and repeated TTS were byte-identical with SHA-256
  `52A11609B165314E8F83919CD4F82AD899346B9945DBEA9D9676431F4E67C548`.
- Within CUDA, cold and repeated cloning were byte-identical with SHA-256
  `8816F29514944C7B8121D17E7620D095D06BA636247BFD4358793500FE8B6FA1`.
- The CUDA default and memory-saver outputs had the same hashes.
- Within CPU, cold and repeated TTS were byte-identical with SHA-256
  `A315C0AD425C99910597FCC4BAB9D80CB5F4C893176EBD9099BA6C6AA7B66BFD`.
- Within CPU, cold and repeated cloning were byte-identical with SHA-256
  `1A2009C0D512773A4B5082BF37EDEDD6A52A37CC6D556772C62EA26550A83B4D`.
- CPU and CUDA WAV bytes are not identical because backend floating-point
  execution differs; deterministic reuse parity was therefore checked within
  each backend rather than asserted across backends.
- The official Python reference has a clean setup path documented above. Per
  maintainer request, Python output parity is intentionally left for maintainer
  validation rather than claimed without their reference environment.

## Backend coverage

| Backend | Coverage |
|---|---|
| Windows CPU | CLI/server/warm-benchmark build; normal TTS, long-form TTS, cloning, cache reuse, graph reuse, WAV decode, timing, and RSS run |
| Windows CUDA 12.4 | CLI/server/warm-benchmark build; normal TTS, long-form TTS, cloning, standalone-path loading, cache/graph reuse, default/memory-saver A/B, WAV decode, timing, RTF, and VRAM run |
| Linux CPU | GitHub Actions compile check passed for CLI, server, and GGUF converter; no model runtime measurement claimed |
| Linux Vulkan | GitHub Actions compile check passed for CLI, server, and GGUF converter; no model runtime measurement claimed |
| macOS CPU | GitHub Actions compile check passed for CLI, server, and GGUF converter; no model runtime measurement claimed |
| Metal | Not enabled or runtime-tested in this validation |

## Known limitations

- OuteTTS is offline-only in this implementation.
- Voice cloning requires an accurate transcript of the reference WAV and rejects
  references longer than 20 seconds.
- Quantized CUDA cloning expands the OuteTTS language-model weights to F32 for
  generation correctness. Default mode can therefore have a high transient
  peak while the aligner is retained; `outetts.mem_saver=true` releases the
  aligner and cached-step graph between phases.
- Long-form output concatenates independently generated chunks; `max_tokens`
  applies to each chunk.
- CPU and CUDA outputs are deterministic within each tested backend but are not
  expected to be byte-identical across backends.
- Python-reference output parity remains pending maintainer validation using the
  exact setup and sampling parameters above.

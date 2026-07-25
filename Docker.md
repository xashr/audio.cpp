# Running audio.cpp in Docker

## Prerequisites

- Docker must be installed and running on your system.
- For CUDA:
  - The [NVIDIA container toolkit](https://github.com/NVIDIA/nvidia-container-toolkit) must be installed.

## Images

The following image flavors are available:

- **full**: Provides the main tools **cli** and **server** and test binaries in one image. When running the container, the first argument selects the tool to execute.

The following backends are supported:
- **cuda12**
- **cuda13**
- **cpu**

The following architectures are supported:
- **amd64**
- **arm64**

## Released Images

New Docker images get released once per day if there are new changes. The images are provided
as multiarch images (amd64/arm64).

Pull the latest images via these tags: 
- **cuda12**: `ghcr.io/0xshug0/audio.cpp:full-cuda12`
- **cuda13**: `ghcr.io/0xshug0/audio.cpp:full-cuda13`
- **cpu**: `ghcr.io/0xshug0/audio.cpp:full-cpu`

Images for a specific day/commit can be found in the
[versions](https://github.com/0xShug0/audio.cpp/pkgs/container/audio.cpp/versions?filters%5Bversion_type%5D=tagged)
history. <br/>
The format is: `full-<backend>-<date>-<shortsha>`, e.g. `full-cuda12-20260725-db7d2c4 `


## Build the Image locally

If you would like to build the images locally, you can use the available
Dockerfiles in `.devops`.

### CUDA

Build with the default CUDA 12.x version. See `.devops/cuda.Dockerfile`.

```bash
docker build -f .devops/cuda.Dockerfile -t local/audio.cpp:full-cuda .
```

Build with a specific CUDA version, for example 13.2.0:

```bash
docker build -f .devops/cuda.Dockerfile -t local/audio.cpp:full-cuda --build-arg CUDA_VERSION=13.2.0 .
```

### CPU

```bash
docker build -f .devops/cpu.Dockerfile -t local/audio.cpp:full-cpu .
```

## Usage

The model directory `<models-dir>` must be mounted into the container.
An additional `<output-dir>` should be mounted for TTS tasks.

### CUDA

```bash
docker run --rm --gpus all -v "<models-dir>:/models:ro" ghcr.io/0xshug0/audio.cpp:full-cuda12 <cli|server> --model /models/<model> <...>
```

### CPU

```bash
docker run --rm -v "<models-dir>:/models:ro" ghcr.io/0xshug0/audio.cpp:full-cpu <cli|server> --model /models/<model> <...>
```

See the fully working [examples](#examples) below.

## Examples

Examples for Docker, including CUDA and CPU, are available in `examples/docker`.

### CLI

The **[examples](examples/docker/cli/EXAMPLE.md)** in `examples/docker/cli`
demonstrate how to run the audio.cpp CLI with `docker run`. The examples include:

- **PocketTTS:** Text-to-Speech
- **Qwen3-TTS:** Text-to-Speech with Voice Cloning

### Server

The **[examples](examples/docker/server/EXAMPLE.md)** in `examples/docker/server`
demonstrate how to run the audio.cpp server with `docker compose`. The examples include:

- **PocketTTS:** Text-to-Speech
- **Qwen3-TTS:** Text-to-Speech with Voice Cloning


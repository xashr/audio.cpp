#!/usr/bin/env bash

mkdir -p output
curl http://localhost:8080/v1/audio/speech -H 'Content-Type: application/json' -o output/speech.wav -d '
{
  "model": "qwen3-tts",
  "input": "You are successfully running a text-to-speech model using audio.cpp, a pure C++ inference engine for audio models.",
  "voice_ref": "/references/ref_audio.wav",
  "reference_text": "$(cat ../references/ref_text.txt)"
}
'

echo "Saved to: output/speech.wav"
#!/usr/bin/env python3
"""Vosk-based streaming dictation server for Neovim.

Commands via stdin: "start", "stop", "lang <path>", "quit".
Outputs JSON lines to stdout.
"""

import os
import sys
import json
import queue
import threading
import sounddevice as sd
from vosk import Model, KaldiRecognizer

SAMPLE_RATE = 16000

audio_queue = queue.Queue()
listening = False
stop_event = threading.Event()
stream = None
recognizer = None
recognizer_lock = threading.Lock()


def emit(msg_type, text):
    print(json.dumps({"type": msg_type, "text": text}), flush=True)


def audio_callback(indata, frames, time, status):
    audio_queue.put(bytes(indata))


def recognize_loop():
    while not stop_event.is_set():
        try:
            data = audio_queue.get(timeout=0.1)
        except queue.Empty:
            continue
        if not listening:
            continue
        with recognizer_lock:
            if recognizer is None:
                continue
            if recognizer.AcceptWaveform(data):
                result = json.loads(recognizer.Result())
                text = result.get("text", "").strip()
                if text:
                    emit("final", text)
            else:
                partial = json.loads(recognizer.PartialResult())
                text = partial.get("partial", "").strip()
                if text:
                    emit("partial", text)


def start_stream():
    global stream
    if stream is not None:
        return
    stream = sd.RawInputStream(
        samplerate=SAMPLE_RATE,
        blocksize=4000,
        dtype="int16",
        channels=1,
        callback=audio_callback,
    )
    stream.start()


def stop_stream():
    global stream
    if stream is None:
        return
    stream.stop()
    stream.close()
    stream = None
    while not audio_queue.empty():
        audio_queue.get_nowait()


def load_model(model_path):
    global recognizer
    model = Model(model_path)
    with recognizer_lock:
        recognizer = KaldiRecognizer(model, SAMPLE_RATE)
    emit("status", "model_loaded:" + os.path.basename(model_path))


def main():
    global listening

    model_path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/.local/share/vosk/vosk-model-small-ru-0.22"
    )
    load_model(model_path)

    stop_event.clear()
    rec_thread = threading.Thread(target=recognize_loop, daemon=True)
    rec_thread.start()

    emit("status", "ready")

    try:
        for line in sys.stdin:
            cmd = line.strip()
            if cmd == "start":
                while not audio_queue.empty():
                    audio_queue.get_nowait()
                start_stream()
                listening = True
                emit("status", "listening")
            elif cmd == "stop":
                listening = False
                stop_stream()
                with recognizer_lock:
                    if recognizer:
                        final = json.loads(recognizer.FinalResult())
                        text = final.get("text", "").strip()
                        if text:
                            emit("final", text)
                emit("status", "stopped")
            elif cmd.startswith("lang "):
                new_path = cmd[5:].strip()
                was_listening = listening
                if was_listening:
                    listening = False
                    stop_stream()
                load_model(new_path)
                if was_listening:
                    start_stream()
                    listening = True
                    emit("status", "listening")
            elif cmd == "quit":
                break
    finally:
        listening = False
        stop_event.set()
        stop_stream()


if __name__ == "__main__":
    main()

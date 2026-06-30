#!/usr/bin/env python3
"""TTS with word highlighting. macOS system voice (Ava Premium) → Piper fallback."""
import sys, os, re, tempfile, subprocess, signal, time, wave

_player = None

def _cleanup(signum=None, frame=None):
    if _player and _player.poll() is None:
        _player.kill()
    sys.exit(0)

signal.signal(signal.SIGTERM, _cleanup)
signal.signal(signal.SIGINT, _cleanup)

PIPER_MODEL_DIR = os.path.expanduser("~/.local/share/piper")
PIPER_MODEL = os.path.join(PIPER_MODEL_DIR, "ryan-high.onnx")

# macOS NSSpeechSynthesizer voice. "Ava (Premium)" — high-quality system voice.
MACOS_VOICE = "com.apple.voice.premium.en-US.Ava"


def _find_words(text):
    """Return [(offset, length), ...] for each word in text."""
    return [(m.start(), m.end() - m.start()) for m in re.finditer(r'\S+', text)]


def _md_to_speech(text):
    """Convert markdown to clean speakable text."""
    t = text
    # Fenced code blocks → "code block" placeholder
    t = re.sub(r'```[^\n]*\n.*?```', ' code block. ', t, flags=re.DOTALL)
    # Inline code → just the content
    t = re.sub(r'`([^`]+)`', r'\1', t)
    # Images ![alt](url) → alt text
    t = re.sub(r'!\[([^\]]*)\]\([^)]*\)', r'\1', t)
    # Links [text](url) → text
    t = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', t)
    # Reference links [text][ref] → text
    t = re.sub(r'\[([^\]]*)\]\[[^\]]*\]', r'\1', t)
    # HTML tags
    t = re.sub(r'<[^>]+>', '', t)
    # Horizontal rules (---, ***, ___, ===)
    t = re.sub(r'^[\s\-=_*·•]{3,}$', '', t, flags=re.MULTILINE)
    # Headers: "## Title" → "Title."
    t = re.sub(r'^#{1,6}\s+(.+)$', r'\1.', t, flags=re.MULTILINE)
    # Bold/italic markers
    t = re.sub(r'\*{1,3}|_{1,3}', '', t)
    # Strikethrough
    t = re.sub(r'~~(.+?)~~', r'\1', t)
    # Blockquotes
    t = re.sub(r'^>\s*', '', t, flags=re.MULTILINE)
    # List bullets (-, *, +, 1.) → remove marker
    t = re.sub(r'^[\s]*[-*+]\s+', '', t, flags=re.MULTILINE)
    t = re.sub(r'^[\s]*\d+[.)]\s+', '', t, flags=re.MULTILINE)
    # Table separators (|---|---|)
    t = re.sub(r'^[\s|:\-]+$', '', t, flags=re.MULTILINE)
    # Remaining special chars that get pronounced
    t = re.sub(r'[→←↑↓|\\`~^{}[\]]', ' ', t)
    # Collapse repeated punctuation
    t = re.sub(r'([.!?,;:]){2,}', r'\1', t)
    # Line breaks → sentence boundary (pause)
    t = re.sub(r'([.!?,;:])\s*\n', r'\1\n', t)
    t = re.sub(r'([^.!?,;:\s])\s*\n', r'\1.\n', t)
    # Collapse blank lines
    t = re.sub(r'\n{2,}', '\n', t)
    return t


def piper_speak(text):
    """Local Piper TTS — fast, offline, male voice, estimated word highlighting."""
    try:
        from piper import PiperVoice
    except ImportError:
        sys.stderr.write("TTS: piper-tts not installed\n")
        return False

    if not os.path.exists(PIPER_MODEL):
        sys.stderr.write("TTS: piper model not found, downloading...\n")
        os.makedirs(PIPER_MODEL_DIR, exist_ok=True)
        import urllib.request
        base = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/high/en_US-ryan-high.onnx"
        try:
            urllib.request.urlretrieve(base, PIPER_MODEL)
            urllib.request.urlretrieve(base + ".json", PIPER_MODEL + ".json")
        except Exception as e:
            sys.stderr.write(f"TTS: download failed: {e}\n")
            return False

    try:
        voice = PiperVoice.load(PIPER_MODEL)
    except Exception as e:
        sys.stderr.write(f"TTS: piper load error: {e}\n")
        return False

    clean_text = _md_to_speech(text)

    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    try:
        from piper.config import SynthesisConfig
        syn_cfg = SynthesisConfig(length_scale=1.15)  # slightly slower
        audio_bytes = b""
        sample_rate = voice.config.sample_rate
        sentence_pause = b"\x00\x00" * int(sample_rate * 0.35)  # 350ms silence between sentences
        for chunk in voice.synthesize(clean_text, syn_config=syn_cfg):
            audio_bytes += chunk.audio_int16_bytes + sentence_pause
        wf = wave.open(tmp.name, "wb")
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(audio_bytes)
        wf.close()
        duration = len(audio_bytes) / (sample_rate * 2)
    except Exception as e:
        sys.stderr.write(f"TTS: piper synth error: {e}\n")
        tmp.close()
        os.unlink(tmp.name)
        return False

    # Estimate word timing proportionally by character midpoint
    words = _find_words(text)
    total_chars = len(text)

    global _player
    _player = subprocess.Popen(
        ["afplay", tmp.name],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

    # Emit word boundaries synchronized with playback
    t0 = time.monotonic()
    for offset, length in words:
        # Estimate start time from character position ratio
        word_time = (offset / total_chars) * duration
        wait = word_time - (time.monotonic() - t0)
        if wait > 0:
            time.sleep(wait)
        sys.stdout.write(f"{offset} {length}\n")
        sys.stdout.flush()

    _player.wait()
    _player = None
    try:
        os.unlink(tmp.name)
    except OSError:
        pass
    return True


def macos_speak(text):
    """macOS NSSpeechSynthesizer with word-level callbacks."""
    try:
        import AppKit, Foundation
    except ImportError:
        return False

    available = [str(v) for v in AppKit.NSSpeechSynthesizer.availableVoices()]
    if MACOS_VOICE in available:
        voice = MACOS_VOICE
    else:
        voice = AppKit.NSSpeechSynthesizer.defaultVoice()
        if not voice:
            for v in available:  # prefer a premium/enhanced en-US voice
                if "en-US" in v and ("premium" in v.lower() or "enhanced" in v.lower()):
                    voice = v
                    break
    if not voice:
        return False

    done = [False]

    class Del(AppKit.NSObject):
        def speechSynthesizer_willSpeakWord_ofString_(self, synth, rng, txt):
            sys.stdout.write(f"{rng.location} {rng.length}\n")
            sys.stdout.flush()

        def speechSynthesizer_didFinishSpeaking_(self, synth, success):
            done[0] = True

    synth = AppKit.NSSpeechSynthesizer.alloc().initWithVoice_(voice)
    delegate = Del.alloc().init()
    synth.setDelegate_(delegate)
    synth.startSpeakingString_(text)

    while not done[0]:
        Foundation.NSRunLoop.currentRunLoop().runUntilDate_(
            Foundation.NSDate.dateWithTimeIntervalSinceNow_(0.1)
        )
    return True


def main():
    text = sys.stdin.read()
    if not text.strip():
        return

    macos_speak(text) or piper_speak(text)

    sys.stdout.write("DONE\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""TTS with word-boundary feedback via NSSpeechSynthesizer."""
import sys
import AppKit
import objc

class SpeechDelegate(AppKit.NSObject):
    def speechSynthesizer_willSpeakWord_ofString_(self, synth, word_range, text):
        loc = word_range.location
        length = word_range.length
        # Output character offset and length for each word
        sys.stdout.write(f"{loc} {length}\n")
        sys.stdout.flush()

    def speechSynthesizer_didFinishSpeaking_(self, synth, success):
        sys.stdout.write("DONE\n")
        sys.stdout.flush()
        AppKit.NSApp.terminate_(None)

def main():
    text = sys.stdin.read()
    if not text.strip():
        return

    synth = AppKit.NSSpeechSynthesizer.alloc().initWithVoice_(None)
    delegate = SpeechDelegate.alloc().init()
    synth.setDelegate_(delegate)
    synth.startSpeakingString_(text)

    AppKit.NSApplication.sharedApplication()
    AppKit.NSApp.run()

if __name__ == "__main__":
    main()

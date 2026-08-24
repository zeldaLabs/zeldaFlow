#!/usr/bin/env python3
"""Noise-robustness regression guard for zeldaFlow's transcription pipeline.

WHAT THIS IS: a tripwire. It renders one synthesized sentence at several
signal-to-noise ratios, pushes each through the real `--selftest` pipeline,
and fails if word error rate degrades past a generous committed threshold.
Its job is to catch a *regression* — a model swap, a VAD parameter change, a
prompt change — that quietly makes zeldaFlow worse in noise.

WHAT THIS IS NOT: a measurement of how zeldaFlow behaves for real users. The
speech is synthesized (perfectly articulated, no Lombard effect), the noise
is synthetic, and the whole microphone path — macOS gain control, the mic
array, Apple's voice-processing mode — is bypassed entirely. Real-world
accuracy is worse than these numbers and MUST NOT be quoted from them.
Real-world behavior is measured by the microphone-path session in
docs/UAT.md, with a human and an actual room.

Requires: sox (brew install sox). Usage: python3 evals/noise-robustness.py
"""
import math, os, re, string, subprocess, sys, tempfile

REF = ("The quarterly review moved to Thursday, so please refactor the audio "
       "recorder and send the updated architecture notes before the meeting.")

# Generous ceilings: real degradation trips these, normal run-to-run drift
# does not. Tightening them is how you make the guard stricter.
BUDGET = {"quiet (+20 dB)": 15.0, "moderate (+10 dB)": 25.0, "loud (+5 dB)": 40.0}

BIN = os.environ.get("ZELDAFLOW_BIN", os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "build/zeldaFlow.app/Contents/MacOS/zeldaFlow"))


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def wer(ref, hyp):
    strip = str.maketrans("", "", string.punctuation.replace("'", ""))
    r, h = ref.lower().translate(strip).split(), hyp.lower().translate(strip).split()
    d = [[0] * (len(h) + 1) for _ in range(len(r) + 1)]
    for i in range(len(r) + 1): d[i][0] = i
    for j in range(len(h) + 1): d[0][j] = j
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (r[i-1] != h[j-1]))
    return 100.0 * d[len(r)][len(h)] / max(1, len(r))


def sox_rms(path):
    m = re.search(r"RMS\s+amplitude:\s+([\d.]+)", sh(f'sox "{path}" -n stat 2>&1').stdout)
    return float(m.group(1)) if m else 0.0


def transcribe(wav):
    """Returns the text the user would actually receive (post-scrubber)."""
    p = subprocess.run([BIN, "--selftest", wav], capture_output=True, text=True, timeout=300)
    filt = re.search(r"^FILTERED: (.*)$", p.stdout, re.M)
    if filt:
        return filt.group(1).strip()
    raw = re.search(r"^RAW: (.*)$", p.stdout, re.M)
    return raw.group(1).strip() if raw else ""


def main():
    if not os.path.exists(BIN):
        sys.exit(f"error: no build at {BIN} — run scripts/build-app.sh first")
    if not sh("which sox").stdout.strip():
        sys.exit("error: sox not installed — brew install sox")

    tmp = tempfile.mkdtemp(prefix="zeldaFlow-noise-")
    clean = os.path.join(tmp, "clean.wav")
    sh(f'say -o "{tmp}/s.aiff" {sh_quote(REF)}')
    sh(f'afconvert -f WAVE -d LEI16@16000 -c 1 "{tmp}/s.aiff" "{tmp}/raw.wav"')
    sh(f'sox "{tmp}/raw.wav" "{clean}" gain -n -6')
    dur = float(re.search(r"([\d.]+)", sh(
        f'soxi -D "{clean}"').stdout.strip() or "0").group(1))
    voice = sox_rms(clean)

    print("zeldaFlow noise-robustness guard  (synthetic — not a product claim)")
    failures = []
    baseline = transcribe(clean)
    print(f"  {'condition':<20}{'WER':>8}  {'budget':>8}")
    print(f"  {'clean':<20}{wer(REF, baseline):>7.1f}%{'—':>9}")

    for label, snr in (("quiet (+20 dB)", 20), ("moderate (+10 dB)", 10), ("loud (+5 dB)", 5)):
        noise = os.path.join(tmp, "n.wav")
        sh(f'sox -n -r 16000 -c 1 -b 16 "{noise}" synth {dur:.2f} pinknoise vol 0.3')
        cur = sox_rms(noise)
        target = voice / (10 ** (snr / 20.0))
        sh(f'sox "{noise}" "{tmp}/n2.wav" gain {20 * math.log10(target / cur):.3f}')
        mixed = os.path.join(tmp, f"mix{snr}.wav")
        sh(f'sox -m "{clean}" "{tmp}/n2.wav" "{mixed}"')
        got = wer(REF, transcribe(mixed))
        budget = BUDGET[label]
        ok = got <= budget
        if not ok: failures.append(f"{label}: {got:.1f}% > {budget:.1f}%")
        print(f"  {label:<20}{got:>7.1f}%{budget:>8.1f}%  {'ok' if ok else 'FAIL'}")

    sh(f'rm -rf "{tmp}"')
    if failures:
        print("FAIL — noise robustness regressed:")
        for f in failures: print("  " + f)
        return 1
    print("OK — noise robustness within budget")
    return 0


def sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


if __name__ == "__main__":
    sys.exit(main())

# 26. Seamless dictation audio: never open a Bluetooth mic, never duck

Status: Accepted
Date: 2026-08-02

## Context

With echo cancellation on and Bluetooth headphones connected, every
dictation was audible as an event: music paused, came back mono and quiet,
recovered a moment later, and the dictation itself started late. Three
mechanisms, confirmed on the reporting user's setup (headset "Jarvis",
default input, 24 kHz):

1. **Opening a Bluetooth mic flips the whole headset** from its
   high-quality playback profile into the hands-free profile. There is no
   way to open a Bluetooth microphone without this.
2. **Apple's voice-processing unit (VPIO) ducks all other system audio**
   by default the moment it engages — and while the unit exists in the
   graph, macOS keeps the stack in voice mode even between recordings.
   The first fix for that (release 4 s after every stop) traded one
   permanent volume drop for a per-dictation down/up cycle.
3. **VPIO spin-up is expensive**: measured 1409 ms cold against 28 ms
   warm — and the mic is not open during spin-up, so a cold start eats
   the first word. The 4 s release made nearly every dictation pay it.

A fourth fact, found while fixing: the VPIO unit refuses to initialise
when steered at an input-only device (`-10875`), so a device override is
only possible on the plain capture unit.

## Decision

Make the seamless path the one where nothing about the audio system
changes:

- **Never open a Bluetooth microphone.** When the default input is
  Bluetooth, capture from the Mac's built-in mic instead — an
  engine-local override (`kAudioOutputUnitProperty_CurrentDevice`); the
  system default is never modified. The built-in array is also simply a
  better microphone than a 24 kHz headset link. Opt-out toggle: "Use Mac
  Microphone with Headphones" (default on), for dictating through the
  headset from across the room.
- **Skip VPIO entirely when output is Bluetooth headphones.** Echo
  cancellation removes *speaker* sound from the mic; with music in the
  user's ears there is no speaker bleed to cancel, so on headphones the
  unit adds nothing and costs everything. This also sidesteps the
  `-10875` constraint: the override applies exactly on the path where
  it is needed.
- **When VPIO does run (speakers), duck at minimum**
  (`voiceProcessingOtherAudioDuckingConfiguration`, macOS 14+): AEC works
  at any playback volume; the duck was never required.
- **Linger 120 s, then release** (injectable for the eval): a working
  session stays on the 28 ms warm path; walking away returns the system
  to exactly its prior state.

## Alternatives considered

- **Release VPIO immediately at stop** — restores audio fastest but makes
  every dictation pay the 1409 ms cold start and cycles voice mode
  audibly per dictation; measured and rejected.
- **Keep VPIO warm forever** — the original defect: system-wide ducking
  while the app merely runs.
- **Steer the VPIO unit at the built-in mic** — fails to initialise
  (`-10875`); discovered by `--evalaudio`, kept as a documented
  constraint rather than fought.
- **Disable echo cancellation by default** — throws away real speaker-
  bleed filtering for speaker users to fix a headphone-only symptom.

## Consequences

**Good**

- On Bluetooth headphones, dictation now touches nothing: no voice mode,
  no duck, no profile flip, start measured at 257 ms — and transcription
  quality improves by moving off the 24 kHz headset mic.
- `--evalaudio` is topology-aware: it reads what is connected and asserts
  the applicable rule (verified against the user's own headset).

**Bad**

- Speaker users still get a minimal duck and a cold start after 2 min of
  quiet; the first dictation after a long pause can clip the first word.
- The Bluetooth-mic refusal means a user whose *only* mic is their
  headset (e.g. Mac mini, lid closed) needs the toggle off — capture
  falls back to the headset with all the profile consequences.
- Transport detection covers Bluetooth/BluetoothLE only; continuity-mic
  and AirPlay routes keep default behaviour.

Evidence: `Sources/zeldaFlow/Audio/AudioRecorder.swift`
(`applyPreferredInputDevice`, ducking configuration,
`releaseVoiceProcessing`), `Sources/zeldaFlow/Support/AudioEvals.swift`;
all numbers measured on the reporting user's hardware 2026-08-02.
Extends ADR 1; revises the interim fix committed a day earlier.

---

## Addendum (2026-08-05): the rule is now enforced, not requested

Two nights after acceptance, the rule failed in production exactly where it
mattered. With the external monitor docked and the headset as default
input, every steer to the built-in mic returned `-10851` — and the
best-effort fallback quietly captured the headset it exists to protect, six
times, delivering 0.00 s of audio each time. Dictation was simply dead, and
the log said "using Jarvis" in lowercase like it was fine.

The `-10851` itself was **environmental**: live probes proved
`kAudioOutputUnitProperty_CurrentDevice` had wedged machine-wide (every
device, every process, every AU lifecycle state — a macOS 27 beta
coreaudiod runtime degradation; `sudo killall coreaudiod` cured it, and a
freshly-launched process steered fine while the long-running app, holding
device IDs from the dead daemon's generation, kept failing). The app bug
was what the wedge exposed: **the never-open-a-Bluetooth-mic rule was a
request, not an invariant.**

Changes:

- `applyPreferredInputDevice` now **throws** when the default input is
  Bluetooth and nothing safe can be steered to — surfacing as a visible
  "Mic error" with the coreaudiod remedy in the message — instead of
  falling back to the headset. A dictation that fails loudly beats one
  that records nothing silently.
- Fallback candidates are enumerated fresh on every attempt (device IDs
  are invalidated wholesale when coreaudiod restarts) and restricted to
  trusted wired transports: built-in, USB, Thunderbolt, PCI, FireWire.
  HDMI/DisplayPort monitor audio, virtual devices, AirPlay, and Continuity
  mics are excluded by allowlist — each is a device that "works" while
  delivering silence (the docked iPhone's Continuity mic was live in the
  failing topology).
- The steer is **verified after `engine.start()`** by reading the unit's
  current device back: prepare/start can rebuild the I/O unit and silently
  revert to the system default. Bluetooth read back ⇒ stop and throw.
- Voice processing is skipped when the default input is Bluetooth: the
  VPIO unit refuses device overrides (`-10875`), so enabling it IS opening
  the headset. This closes the unenforced path the original ADR listed
  under "Bad".


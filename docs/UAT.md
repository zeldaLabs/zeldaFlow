# zeldaFlow user-acceptance checklist

A manual pass over everything the automated harnesses
([docs/TESTING.md](TESTING.md)) can't reach: the hardware hotkey, TCC
permissions, real app control, windowing, audio devices, and real calls. Run
it on a real Apple Silicon Mac before cutting a release.

Sections 0–10 are the ~20-minute core. Sections 11–15 cover meeting capture
and need real calls with real people, so budget another ~25 minutes and
schedule them — they can't be faked with a test fixture.

**You need:** macOS 15+, models installed (`scripts/setup.sh`), a build
signed with a stable identity so TCC grants stick (`scripts/make-cert.sh`
once, then `scripts/build-app.sh`), a contact in Contacts you can safely
email, and — for section 9 — at least one external display, ideally via a
dock or monitor that exposes its own audio device (HDMI/USB audio).

**For sections 11–15 you additionally need:** the System Audio Recording
permission granted, a real Zoom/Meet/Teams call, a WhatsApp Desktop account
you can call from, and — for diarization — one call with two or more remote
participants.

Keep a log tail open in a terminal for the whole run:

```bash
tail -f ~/Library/Application\ Support/zeldaFlow/zeldaflow.log
```

## 0. Preflight (2 min)

- [ ] `scripts/build-app.sh` completes and reports a signing identity
      (warns loudly if it fell back to ad-hoc — permissions won't survive
      rebuilds in that case)
- [ ] `./build/zeldaFlow.app/Contents/MacOS/zeldaFlow --selftest <wav>` exits 0
      (see TESTING.md for generating a WAV)
- [ ] `./build/zeldaFlow.app/Contents/MacOS/zeldaFlow --evalcommands` prints
      `OK — all pins hold`

## 1. First-run onboarding (3 min)

On a fresh install the cinematic onboarding opens by itself (it appears
whenever mic permission, Accessibility, or the whisper model is missing).
On a configured machine, replay it via menu bar icon → **Setup &
Permissions…**.

- [ ] Onboarding opens: the animated night-sky arrival scene plays (with
      Reduce Motion enabled, scenes render settled instead of animating)
- [ ] Name step: enter a first name and continue
- [ ] Permission cards: each card triggers the right system prompt/pane,
      and flips to granted within ~1 s of you granting (it polls)
- [ ] Warm-up: shows progress and advances once the whisper model is ready;
      with the model missing it shows the setup problem, never an endless
      spinner
- [ ] Finale completes and the window closes
- [ ] Your name appears in the Hub greeting and in Hub → Dictionary's word
      list (it now biases transcription)

## 2. Permissions (1 min)

- [ ] Menu-bar icon is present; there is no Dock icon (accessory app)
- [ ] The status menu's top line reports no setup problems and the speech
      model as ready
- [ ] Microphone and Accessibility show granted for zeldaFlow in System
      Settings → Privacy & Security

## 3. Push-to-talk dictation (2 min)

- [ ] Copy something to the clipboard (for the restore check below). Click
      into a text field, **hold Fn**, speak a sentence: the pill appears
      bottom-center of the screen containing the focused window, the
      waveform reacts to your voice, and a live preview streams your words
- [ ] Release Fn: the text inserts at the cursor within ~1–2 s
- [ ] Paste (⌘V): your **previous** clipboard content comes back — the
      insert didn't permanently clobber it
- [ ] Tap Fn briefly (under 0.3 s) and release: nothing inserts and nothing
      is logged (it's treated as a tap). Hold for just over 0.3 s: nothing
      inserts, and zeldaflow.log gains a `session discarded: …s of audio
      (below 0.35s minimum)` line
- [ ] Hold Fn, then press **Esc** while recording: canceled, nothing inserts

## 4. Hands-free (1 min)

- [ ] **Double-tap Fn**: recording starts and stays on with fingers off the
      keyboard
- [ ] Click into a *different* text field mid-dictation, then tap Fn: the
      text lands in the newly focused field (insertion targets where the
      cursor is when you stop)

## 4b. Long-form dictation (10+ min, optional but release-recommended)

First raise Settings → Dictation → "Max recording" above 10 minutes (the
default cap is 5 — a session auto-finishes at the cap).

- [ ] **Double-tap Fn and talk for 10+ minutes** (read an article aloud):
      the live preview keeps updating, memory stays bounded (~1.3 GB peak
      during transcription), and on tap-to-finish the FULL text inserts —
      compare the ending of what you said with the ending of the inserted
      text
- [ ] zeldaflow.log shows `exceeds the cleanup context budget — falling back
      to light cleanup` for the long transcript: every word is kept and
      Gemma cleanup is skipped by design (its context window can't fit long
      transcripts — the file-based equivalent of this check runs in the
      benchmark suite, see PERFORMANCE.md)

## 5. Command mode — one per action family (5 min)

**Triple-tap Fn** (the pill switches to its command styling), then speak.
The first time zeldaFlow controls each app, macOS shows a one-time Automation
prompt — accept it. (The safe, reversible subset of these families also
runs automated as `zeldaFlow --evalactions` — see TESTING.md §4; the voice
path below additionally exercises STT and the parser end-to-end.)

- [ ] **Apps** — "open Safari": Safari launches or comes frontmost
- [ ] **Web** — "what's the weather in Paris": either an instant answer in
      the pill or a Google search in your default browser
- [ ] **Music** — "play <song> by <artist>": the *right track* actually
      plays in your music app; then "pause" stops it
- [ ] **Volume** — "set the volume to 30": system volume changes
- [ ] **Productivity** — "remind me to test zeldaFlow tomorrow at 9am": the
      reminder exists in Reminders with the right date/time (this family
      also covers Notes and Calendar templates)
- [ ] **Navigation** — "navigate to the airport": Apple Maps opens with
      driving directions computed
- [ ] **Comms gate** — "email <contact> saying the build is ready": the
      pill shows the recipient and waits. Press **Esc**: canceled, nothing
      sent. Repeat and **tap Fn**: the mail sends from your account
- [ ] **Multi-intent (LLM path)** — "open Notes and play some jazz": both
      happen, in order
- [ ] **Agent** *(only if the Claude Code CLI is installed)* — "what's on
      my screen" answers in the pill; then a background task ("check my
      GitHub notifications") **always** demands a Fn-tap confirmation, even
      with confirm-before-send turned off in Settings

## 6. Speak-to-Edit (1 min)

- [ ] Select a long sentence in any editor, triple-tap Fn, say "make this
      shorter": the selection is replaced with a shorter rewrite
- [ ] With nothing selected, the same command fails with a clear pill
      message and pastes nothing

## 7. Click-to-type bar (1 min)

- [ ] The idle nub sits bottom-center and grows a waveform on hover
- [ ] Click it: a Spotlight-style bar opens where you clicked, ready for
      typing, **without** deactivating your frontmost app
- [ ] Type `open safari` and press Return: same result as speaking it
- [ ] Click anywhere else: the bar closes (Esc closes it too)

## 8. Hub pages (2 min)

Menu bar → **History & Settings…**

- [ ] **Home**: greeting uses your onboarding name; streak/WPM/word-count
      cards reflect the dictations you just did; the checklist card tracks
      progress
- [ ] **History**: this session's dictations are listed with timing
      metadata; the copy button puts the text on the clipboard
- [ ] **Dictionary**: add a distinctive word, dictate it, and it's spelled
      right; a learned-word suggestion appears after dictating an unusual
      word twice and can be approved or dismissed; add a replacement pair
      and it applies to the next transcript
- [ ] **Settings**: switch AI cleanup mode and watch the Gemma status row
      track the server; changed toggles persist across relaunch

## 9. Multi-monitor (4 min)

This section exists because of verified windowing and audio findings that
today's fixes address — exercise all of it. You need an external display;
use a dock or monitor with its own audio device for the last two items.
Keep the zeldaflow.log tail visible.

- [ ] **Attach while idle — nub stays put**: with zeldaFlow idle, plug in the
      external display. The nub stays parked on the screen it was already
      on — visible, clickable, bottom-center — and does NOT hop to the new
      display (previously its frame could go stale in dead coordinate
      space; a later fix also stopped it roaming on unrelated changes)
- [ ] **Detach while idle**: arrange so the nub sits on the external, then
      unplug it. The nub reappears bottom-center of a remaining screen; if
      the display handshake leaves the screen list momentarily empty, it
      settles within ~1 s (retry path) instead of vanishing
- [ ] **Recording follows keyboard focus, not the mouse**: focused window
      on monitor A, mouse pointer parked on monitor B. Hold Fn: the
      waveform and live preview render at the bottom of **monitor A** —
      the screen you're looking at. After the session, the pill stays on
      monitor A until the next recording targets a different screen
- [ ] **Type bar opens in place**: click the nub — the type bar opens at
      the nub's own position and stays on that screen through submit and
      the result notice; no jumping between screens
- [ ] **Attach/detach while recording**: start a dictation, then plug or
      unplug the dock mid-sentence. Either capture continues and the text
      inserts correctly, or the session cancels with the visible
      "Microphone changed — try again" notice — never a silent freeze
- [ ] **Hub survives losing its display**: drag the Hub window onto the
      external, close it, unplug that display, then menu → History &
      Settings…. The window appears centered on a live screen (previously
      it re-opened at the dead display's coordinates and the click "did
      nothing")
- [ ] **Dock adds an audio device — capture stays real**: dock while idle
      (zeldaflow.log may log `AudioRecorder: engine reset after idle-time
      audio device change`), then dictate. The log must show
      `AudioRecorder: capturing "<device>" (… Hz, … ch)` naming the mic
      you expect. If the transcript comes back empty, the log must say
      why: `… peak level ≈ 0 — "<device>" delivered silence (did the
      default mic change?)` — the classic docked-monitor failure, now
      visible instead of silent. If that fires, pick the real mic in
      System Settings → Sound → Input
- [ ] **Retry captures**: after fixing the input device, dictation inserts
      normally and the `capturing` line names the right device

## 10. Microphone path (15 min, hardware — do this before any release)

This is the one section no harness can replace. `evals/noise-robustness.py`
proves the *decoder* tolerates noise, but it feeds audio from a file and
therefore never exercises macOS input gain, the MacBook mic array, or
Apple's voice-processing mode — which is tuned for a near-field talker and
may actively suppress a distant voice as if it were noise. That behavior is
what actually decides whether zeldaFlow works in a real room, and it can only
be observed with a real microphone.

The variable under test is **Filter Background Music** (menu → Agent), which
turns Apple voice processing on and off. Everything else is held constant:
one room, one person, one script.

**Script** (say exactly this each time, at a normal speaking volume — do not
raise your voice for the far positions, that would hide the effect):

> "The quarterly review moved to Thursday, so please refactor the audio
> recorder and send the updated architecture notes before the meeting."

Keep a terminal open on `tail -f ~/Library/Application\ Support/zeldaFlow/zeldaflow.log`.
For every trial, record the inserted text and the `AudioRecorder: capturing
"<device>"` line. A trial "passes" if the sentence is usable — a wrong word
or two is fine, a mangled or empty result is not.

**Round A — voice processing OFF (default)**

- [ ] Normal posture (~30 cm, hands on keyboard) — baseline; must be perfect
- [ ] Arm's length (~60 cm, leaning back)
- [ ] Standing beside the desk (~1.2 m)
- [ ] Across the room (~2.5–3 m) — record where it stops being usable
- [ ] Normal posture with music playing **from the Mac's own speakers** at a
      comfortable level — this is the case the toggle exists for

**Round B — Filter Background Music ON** (repeat all five)

- [ ] Normal posture — **critical check**: voice processing must not make
      the easy case worse. If baseline accuracy drops here, the toggle is
      doing harm and its default matters.
- [ ] Arm's length · [ ] ~1.2 m · [ ] ~2.5–3 m
- [ ] Normal posture with Mac speakers playing music — compare directly
      against the Round A equivalent; this pair is the whole reason the
      feature exists

**Round C — one adversarial condition, whichever toggle did better**

- [ ] Someone else talking nearby (a video on a phone works) at normal
      posture. Expect degradation; what you are checking is the *failure
      mode* — an honest "Didn't catch that" is acceptable, silently pasting
      wrong words is not, and pasting anything resembling your dictionary
      terms is a bug (see ADR 0022)

**Record the outcome as three numbers**: the distance at which dictation
stops being usable with the toggle off, the same with it on, and whether the
toggle helped or hurt the music case. Those three answers are what belongs
in user-facing documentation — not the synthetic numbers from the eval
script.

## 11. Meeting capture (10 min, needs a real call)

The one part of the app that records other people. Every check here is about
whether it starts when it should and — more importantly — stays off when it
shouldn't.

**Detection starts a recording (ADR 27)**

- [ ] Join a real Zoom/Meet/Teams call. Within ~10–15 s the pill shows the
      **recording chip**, and the log shows the detection reason
- [ ] The chip is visible for the whole call — this is the consent mechanism,
      so if it's ever hidden while recording, that's a release blocker
- [ ] **Stop** ends the meeting and keeps the transcript
- [ ] **Discard** ends it and keeps nothing — verify the meeting is absent
      from the Meetings page afterwards
- [ ] Dictation still works during a meeting: hold Fn, speak, text lands.
      Dictation must win the Whisper queue (ADR 29)

**Nothing that isn't a meeting may trigger**

- [ ] Play a YouTube video with the mic idle → **no** recording starts
- [ ] Record a voice memo in another app → **no** recording starts
- [ ] Open a meeting app without joining a call → **no** recording starts
- [ ] FaceTime with the toggle off → **no** recording starts

**After the call**

- [ ] Transcript shows both sides, labelled You / Them
- [ ] Notes generate automatically: summary, decisions, action items
- [ ] Nothing in the notes is invented — spot-check three action items
      against the transcript. A 2B model inventing labels is the known
      failure mode (ADR 30)
- [ ] **`mic.wav` and `system.wav` are gone** from
      `~/Library/Application Support/zeldaFlow/meetings/<id>/` once the
      transcript finalizes. This is the privacy guarantee — verify it in
      Finder, not by assumption
- [ ] Export as Markdown, txt, SRT, and JSON — each opens correctly

## 12. WhatsApp call capture (5 min, opt-in — ADR 33)

WhatsApp's mic also records voice notes and camera videos, so mic activity
alone must not read as a call. The corroboration is sustained mic **and**
output on the same process. This is the check that ADR 33 names as its
remaining open risk: if WhatsApp keeps an output unit registered while idle,
`IsRunningOutput` could read true during a voice note and defeat the dwell.

- [ ] Enable Settings → **Also record WhatsApp calls** (default is off)
- [ ] Confirm it is genuinely off by default on a fresh profile

With the log tailing for `MicActivityMonitor: mic holders ->` and its `+out`
markers:

- [ ] **Record a voice note longer than 15 s** → a meeting must **NOT**
      start. This is the failing case if the dwell is defeated
- [ ] **Record a camera video** → a meeting must **NOT** start
- [ ] **Place a real call** → a meeting **MUST** start within ~10–15 s
- [ ] End the call → the meeting finalizes with a usable transcript
- [ ] Turn the setting back off → a subsequent call starts nothing

If a voice note starts a meeting, discard it, turn the toggle off, and treat
it as a blocker — this is recording someone without the corroboration the
feature promises.

## 13. Speaker diarization (3 min, needs a 3+ person call — ADR 31)

Diarization separates the far side into speakers. It never identifies them.

- [ ] After a call with two or more remote people, the transcript shows
      **Speaker 1 / Speaker 2 / …** rather than one undifferentiated "Them"
- [ ] Rename a speaker — the name applies across the whole transcript
- [ ] Renames survive closing and reopening the meeting
- [ ] An hour-long meeting diarizes in roughly 30–60 s; the UI stays
      responsive throughout (it runs on the ANE, not the GPU)
- [ ] With the diarizer models absent, the app degrades honestly — You/Them
      labels, no crash, and it says why

## 14. Editable meeting notes (3 min — ADR 32)

The data-loss path. `MeetingDetailView.deinit` flushes the debounced draft,
and no automated test covers it.

- [ ] Open a meeting, edit the notes, wait ~2 s, navigate away, come back —
      the edit is there
- [ ] **Edit, then navigate away immediately** (within the debounce window),
      come back — **the edit must still be there.** This is the check
- [ ] Edit, then quit the app immediately — reopen, edit survives
- [ ] Press **Regenerate** while not editing — notes are replaced
- [ ] Start editing, and confirm a background regenerate does **not** stomp
      your draft mid-edit
- [ ] Markdown renders correctly after saving (headings, lists, bold)

## 15. Answer pill → chat note (2 min — ADR 36)

- [ ] Triple-tap Fn and ask a question ("what's the capital of Peru")
- [ ] The answer pill appears and is **clickable**
- [ ] Clicking it expands into the chat note (640×460), which takes key focus
- [ ] Type a follow-up in the chat note — it answers in context
- [ ] Ask again and **don't** click: the pill fades on its own timer
- [ ] Known and accepted (ADR 36): while the answer pill is up, clicks in its
      transparent margins are swallowed rather than reaching the app beneath.
      Confirm this is the *only* click-through cost — the pill must not eat
      clicks after it fades

## Sign-off

- [ ] zeldaflow.log contains no unexplained errors from this run
- [ ] Every unchecked box above is either fixed or explicitly waived in the
      release notes

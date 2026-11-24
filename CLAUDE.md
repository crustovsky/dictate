# dictate

Hold-to-talk speech-to-text on my laptop. Two backends, one key each: ElevenLabs in the cloud, and Whisper on the laptop's NPU. The main targets are Claude Desktop and Claude Code (in kitty), but it types into whatever window has focus.

## Principles

- Easiest and lightest setup wins. One small script, one server, no extra daemons.
- Use the silicon that is there: local speech recognition runs on the XDNA2 NPU, not the CPU or GPU.
- Use the right tool for each part: flm for local inference, Hyprland for hotkeys, Quickshell for status.
- The key I press is the choice of backend. No modes to remember, no silent fallback from one to the other.
- Keep things simple and readable. No emdashes anywhere: code, comments, docs or commit messages.

## Environment

- Laptop: Ryzen AI 9 365 (XDNA2 NPU, Radeon 880M), 32 GB RAM.
- Arch, Hyprland started via uwsm, kitty, kalenica (my Quickshell bar, `~/Development/repos/kalenica`).
- Tools: `flm`, `pw-record` (PipeWire), `curl`, `jq`, `wtype`, `ffmpeg`, `notify-send`.

## How it works

```
SUPER + D (press)          -> dictate start cloud  -> pw-record to $XDG_RUNTIME_DIR/dictate/clip.wav
SUPER + SHIFT + D (press)  -> dictate start local
either key (release)       -> dictate stop         -> silence gate -> ElevenLabs or flm -> wtype
flm serve --asr whisper-v3:turbo  -> systemd user service flm-asr, NPU, 127.0.0.1:52625
kalenica Dictate.qml              -> watches $XDG_RUNTIME_DIR/dictate/state
```

- Language is auto-detected by both backends. `dictate start local en` forces one if detection misbehaves; that is a bind edit, not a script change.
- `stop` takes no argument: `start` writes the backend to `mode`, `stop` reads it. Either key's release ends the recording.
- State file: `idle`, or `recording <backend>` / `transcribing <backend>`. The bar treats the first word as the state and shows the second as a label, so any other tool writing one or two words drives it too.
- A failed request shows one notification and types nothing.
- `dictate test` checks the whole setup (tools, microphone level, both backends with a generated tone, binds) and exits non-zero on a failure. Run it first when something stops working.

## Files

```
bin/dictate               the script; symlinked to ~/.local/bin/dictate
systemd/flm-asr.service   symlinked into ~/.config/systemd/user/, enabled
hypr/dictate.lua          the four binds; symlinked to ~/.config/hypr/dictate.lua, loaded by require("dictate")
test/compare              run both backends on a clip: test/compare rec|run pl|en|auto
~/.config/dictate/env     ELEVENLABS_API_KEY for bin/dictate (not in the repo)
.env.local                the same key for test/compare (gitignored)
```

The bar indicator lives in kalenica, not here: `Dictate.qml`, plus `modules.dictate.stateFile` in its `config.json`.

Read the files for details; they are short and commented. Do not paste their content back into this document.

## What was measured (2026-11-24, flm 1.0.13, ElevenLabs scribe_v3)

Latency, single runs unless noted:

| Clip | flm | ElevenLabs |
|---|---|---|
| 4 s Polish | 1.2 s | 0.7 s |
| 5 s, through `dictate stop` | 1.7 s | 1.1 s |
| 28 s Polish | 4.0 s | 1.8 s |
| 179 s Polish radio piece | 32 s | 9.6 s |
| 394 s English audiobook | 46 s | 7.6 s |

- ElevenLabs latency on short clips varied from 0.7 s to 3.0 s; flm stayed between 1.1 s and 1.6 s.
- Polish accuracy: ElevenLabs clearly better. On the radio piece flm made about 15 errors (lost "szcz" clusters, invented words), ElevenLabs one.
- English accuracy (native narrator): a tie on ordinary words; both miss fantasy names.
- flm is fragile on very short fragments (a 2 s mid-sentence cut came out as nonsense).
- Auto-detect picked the right language on four short native clips with both backends. Not yet tested on my accented English or on Polish mixed with English terms.
- Silence: flm invents subtitle sign-offs ("Dziękuję.", "you"); ElevenLabs returns nothing. Hence the gate in the script: clips under 0.5 s or with a mean level below -50 dB are dropped. Room noise on the Jabra measured -70 dB mean, speech clips -30 to -18 dB.
- flm memory with `WHISPER_CACHE_DEQUANT=0`: about 1.05 GB, mostly NPU buffers that do not show in RSS. Without it, about 2.4 GB for about 0.2 s less per request.
- Power (package, on AC): idle 10 to 13 W, NPU transcribing 18 W average and 23.5 W peak with the CPU cores at 0.5 W, a CPU busy loop 41 to 45 W. A loaded but idle model costs nothing measurable. Read `/sys/class/powercap/intel-rapl:0/energy_uj` to repeat this; no root needed.

## flm facts

- NPU only; there is no CPU or GPU fallback. No realtime or streaming transcription route, only `POST /v1/audio/transcriptions`.
- `language`, `prompt` and `response_format` are honoured; an unknown language code returns HTTP 400. Omitting `language` auto-detects.
- Forcing the wrong language translates instead of transcribing (`en` on Polish audio gave English text).
- A `prompt` (the `hint` variable in the script, empty by default) adds about 0.6 s per clip and made transcripts slightly worse in both long tests. Use it only for specific misheard words.
- Greedy decoding, no no-speech gate. Transcripts are not logged unless `FLM_LOG_RAW_OUTPUT` is set.
- The server is up about 1 s after start; the first request is slower (about 1.7 s).

## ElevenLabs facts

- `POST https://api.elevenlabs.io/v1/speech-to-text`, header `xi-api-key`, fields `file`, `model_id=scribe_v3`, optional `language_code`.
- The script also sends `tag_audio_events=false`, `timestamps_granularity=none` and `no_verbatim=true` (drops fillers like "uh").
- `keyterms` roughly doubled the request time with no change in the text; not used.
- Transcription draws on subscription credits. The key was created by `npx @elevenlabs/cli onboard`; no SDK is installed on purpose.

## Traps

- **xrt versions.** flm needs `xrt` and `xrt-plugin-amdxdna` at the same version. `xrt` is held at 1:2.21.75-14 by hand; it is not in `IgnorePkg`, so a `pacman -Syu` can bring 2.25.0 back. Then `flm serve` fails with `undefined symbol` and `No such device with index '0'` while `flm validate` still passes. Trust a real request, not `flm validate`.
- **`tail --pid` polls once a second.** Waiting for the recorder without `-s 0.02` adds up to 1 s to every dictation.
- **Kalenica hot reload.** Adding an inline component to `Config.qml` fails on live reload with "is not a type"; `systemctl --user restart quickshell` loads it fine.
- **`~/.config/quickshell` is a copy of kalenica, not a symlink.** Changes have to be copied over.
- **Hyprland bind callbacks block the compositor.** The binds use `hl.dsp.exec_cmd` only.
- **`SUPER + V` is toggle floating**, which is why dictation is on `D`.

## Still to check with my own voice

1. Both keys in Claude Desktop and in kitty: text arrives, Polish diacritics are right. If `wtype` fails there, fall back to `wl-copy` plus a paste keystroke.
2. Auto-detect on accented English and on Polish with English tech terms. Compare with `test/compare rec auto` against `rec pl` and `rec en`.
3. The first syllable: `pw-record` needs about 150 ms before it captures. See whether speech right after the key press gets clipped.
4. Text typed while SUPER is still held: does it fire Hyprland binds (`SUPER + C` closes a window)?
5. Letting go of SUPER before D: no release bind fires and the recording runs to the 120 s cap. See how often that happens before adding anything.
6. The bar indicator, left of the active window title: red microphone plus a cloud or chip glyph while recording, plain while transcribing.
7. The -50 dB silence threshold with the microphone I actually use.

## Later

- If one backend ends up unused, drop its key rather than adding a mode switch.
- Steam Machine (no NPU): the cloud key works there as is; for local, voxtype with Whisper on Vulkan is the likely answer, and it can write the same state file.

## Out of scope

- voxtype on the laptop: it has no AMD NPU engine (its NPU path is OpenVINO, Intel only). In remote mode it would only wrap the same flm call and add a second daemon.
- Realtime transcription (text while speaking): needs a websocket and a long-lived process, which is past what a bash script should do.
- Choosing the backend from the bar: a toggle is a mode to forget; the bar only shows state.
- Lemonade (adds nothing over `flm serve`).
- Claude Desktop's own dictation (not available on Linux).
- Claude Code `/voice` (cloud, Claude Code only), kept as a zero-setup option.

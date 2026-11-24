# dictate

Hold-to-talk dictation for Hyprland. Hold a key, speak, let go: the text is typed into the focused window.

> There are many dictation tools for Linux. This one is a bash script,
> because my laptop has an NPU that did nothing all day, and because
> I speak Polish.

Two keys, two backends:

| Key | Backend | Audio goes to |
|---|---|---|
| `SUPER + D` | ElevenLabs Scribe | the cloud |
| `SUPER + SHIFT + D` | Whisper large-v3-turbo via [FastFlowLM](https://github.com/ROCm/FastFlowLM) | the laptop's AMD NPU, nowhere else |

The key you press is the choice. There is no mode to remember and no silent fallback from one backend to the other.

It is one bash script (`bin/dictate`), one systemd unit and four Hyprland binds. This is my own setup, published as is: the reference machine is a Ryzen AI 9 365 laptop on Arch. Expect to adapt it, not install it.

## Why

There are finished tools for this, and [voxtype](https://github.com/peteonrails/voxtype) is the good one. If it fits your machine and your language, use it; it does far more than this does. It did not fit mine, for two reasons.

**The NPU.** A Ryzen AI laptop ships with a neural processor that Linux mostly ignores. Voxtype's NPU engine is OpenVINO, which means Intel. On AMD it runs Whisper on the CPU or on the integrated GPU, and that is exactly the load I did not want on a laptop: a CPU-bound job took the package from about 11 W to over 40 W here, while Whisper on the NPU added about 7 W and left the cores asleep. FastFlowLM is what runs Whisper on this NPU today. Voxtype can talk to it in remote mode, but then it is a second daemon wrapped around one `curl` call.

**Polish.** The model that fits on the NPU is Whisper large-v3-turbo. It is fine in English and loses the plot in Polish: on a three minute radio piece about the beetle of Szczebrzeszyn it made about fifteen errors, "Wługo pyta" for "Wół go pyta" among them. ElevenLabs Scribe made one, and came back three times sooner. Its API is not the OpenAI shape that local tools expect, so it does not slot into them as a backend.

So neither backend wins. The cloud one is better at my language and the local one keeps my voice on my desk, works offline and uses silicon I already paid for. That is a decision to make per sentence, not per install, which is why it is two keys and not a setting.

The rest is what Linux already has. Hyprland knows when a key goes down and when it comes up, PipeWire records, `wtype` types. What was missing is the glue between them, and glue is a shell script. It is what it is.

## How it works

```
key press    -> dictate start cloud|local -> pw-record writes a wav to $XDG_RUNTIME_DIR/dictate/
key release  -> dictate stop              -> silence gate -> ElevenLabs or flm -> wtype
```

- Both backends detect the language themselves. `dictate start local en` forces one.
- Clips shorter than 0.5 s or quieter than -50 dB on average are dropped before any request. Whisper invents text for silence ("Thank you.", "you"), and this keeps it out of your windows.
- The recording is deleted after every dictation.
- A failed request shows one notification and types nothing.

## Requirements

- Hyprland 0.55 or newer with the Lua config, PipeWire (`pw-record`), `wtype`, `curl`, `jq`, `ffmpeg`, `notify-send`.
- Cloud key: an [ElevenLabs](https://elevenlabs.io) API key. Transcription uses your credits.
- Local key: an AMD XDNA2 NPU (Ryzen AI 300 series) with a working `flm`. FastFlowLM is NPU only, so there is no CPU or GPU fallback.

Either key works without the other. Without an NPU, skip the service and the local bind.

## Install

```bash
git clone https://github.com/crustovsky/dictate && cd dictate

# the script
ln -s "$PWD/bin/dictate" ~/.local/bin/dictate

# cloud: the API key, readable only by you
mkdir -p ~/.config/dictate
echo 'ELEVENLABS_API_KEY=your-key' > ~/.config/dictate/env
chmod 600 ~/.config/dictate/env

# the keys
ln -s "$PWD/hypr/dictate.lua" ~/.config/hypr/dictate.lua
# then add to your hyprland.lua:  require("dictate")
```

The binds call `~/.local/bin/dictate` by full path, because Hyprland's `PATH` usually does not include that directory.

That is enough for the cloud key. The local key needs the next section.

## Whisper on the NPU

The local key talks to FastFlowLM (`flm`), which serves Whisper from the NPU over an OpenAI-style HTTP API on `127.0.0.1:52625`. These are the steps as they worked on Arch with flm 1.0.13; other distros need the same pieces under other names.

**1. Driver and runtime.** The `amdxdna` kernel driver is in the mainline kernel (6.14 or newer); no DKMS package is needed. The rest comes from the `extra` repo:

```bash
sudo pacman -S fastflowlm xrt xrt-plugin-amdxdna
```

**2. Locked memory.** flm pins its buffers, and the default limit of 8 MiB is far too low. Lift it in `/etc/security/limits.conf`, then log out and back in:

```
*    soft    memlock    unlimited
*    hard    memlock    unlimited
```

**3. Check the stack.** This should list the NPU, its firmware and `Memlock Limit: infinity`:

```bash
flm validate
```

**4. Get the model.** About 620 MB, stored under `~/.config/flm`:

```bash
flm pull whisper-v3:turbo
```

**5. Prove it with a real request.** `flm validate` can pass while the server still cannot open the NPU, so trust this and not step 3. Start the server in one terminal:

```bash
flm serve --asr whisper-v3:turbo
```

and send it any short recording from another:

```bash
curl http://127.0.0.1:52625/v1/audio/transcriptions -F file=@clip.wav -F model=whisper-v3
```

A JSON answer with a `text` field means the NPU is doing the work. Stop the server with Ctrl+C.

**6. Run it as a service.** The unit starts it with your session and keeps the model loaded, which is what makes a dictation take about a second:

```bash
ln -s "$PWD/systemd/flm-asr.service" ~/.config/systemd/user/
systemctl --user enable --now flm-asr
```

Things worth knowing:

- **Memory.** The unit sets `WHISPER_CACHE_DEQUANT=0`: about 1 GB resident instead of 2.4 GB, for about 0.2 s more per request. Most of it is NPU buffers, which do not show up as the process's own memory.
- **Idle cost.** A loaded but idle model drew nothing I could measure.
- **If the server dies with `No such device with index '0'`,** `xrt` and `xrt-plugin-amdxdna` have drifted to different versions. It happened here when Arch updated one before the other. Downgrade `xrt` to match the plugin and hold it in `IgnorePkg` until the plugin catches up.
- **Language.** The script sends none and lets Whisper detect it. Forcing the wrong one does not garble the text, it translates it.
- **The standalone ASR server** (no chat model loaded next to it) needs flm 1.0.12 or newer.

## Check the setup

```
$ dictate test
tools
  ok    pw-record
  ...
microphone (records one second, kept on this machine)
  ok    recorded at -68 dB, silence is below the -50 dB gate
local backend
  ok    flm 1.0.13
  ok    flm-asr service is running
  ok    answered in 1095 ms
cloud backend
  ok    key file is private
  ok    answered in 687 ms
hotkeys
  ok    script is at ~/.local/bin/dictate
  ok    2 dictation binds registered in Hyprland
all good
```

It checks the tools, records one second from the default microphone and reports its level, sends a generated tone to each backend to prove it answers, and looks for the binds in Hyprland. Your voice is not sent anywhere during a test. The cloud check uses about a second of ElevenLabs credit. It exits non-zero if anything failed, and a backend you did not set up shows as a failure you can ignore.

## Tuning

The knobs are variables at the top of `bin/dictate`:

| Variable | Default | Meaning |
|---|---|---|
| `min_bytes` | `16000` | clips smaller than this (0.5 s) are dropped |
| `min_mean_db` | `-50` | clips quieter than this on average are dropped; run `dictate test` in silence to see your room's level, and keep the gate above it |
| `hint` | empty | words the local model mishears, sent as a Whisper prompt; costs about 0.6 s per clip |

## Status for a bar

The script writes its state to `$XDG_RUNTIME_DIR/dictate/state`:

```
idle
recording cloud
transcribing local
```

The first word is the state, the second the backend. Anything that can watch a file can show it. [kalenica](https://github.com/crustovsky/kalenica), my Quickshell bar, has a module for it.

## Comparing the backends

`test/compare` runs the same clip through both and prints the text and the time for each:

```bash
test/compare rec pl            # record until Enter, then compare
test/compare rec auto          # same, with language detection
RUNS=3 test/compare run en test/clips/*.wav
```

It reads the ElevenLabs key from the environment or from `.env.local` in the repo root.

What I measured on my machine, as single runs:

| Clip | Local (NPU) | ElevenLabs |
|---|---|---|
| 4 s Polish | 1.2 s | 0.7 s |
| 28 s Polish | 4.0 s | 1.8 s |
| 3 min Polish radio piece | 32 s, about 15 errors | 9.6 s, 1 error |
| 6.5 min English audiobook | 46 s | 7.6 s |

- Polish: ElevenLabs was clearly more accurate.
- English from a native narrator: a tie on ordinary words.
- ElevenLabs latency on short clips varied from 0.7 s to 3.0 s; the NPU stayed between 1.1 s and 1.6 s.
- The NPU added about 7 W to package power while transcribing, with the CPU cores idle.

## Known limits

- If you release `SUPER` before `D`, no release bind fires and the recording runs until its 120 s cap.
- `pw-record` needs about 150 ms to start, so a word spoken the instant you press may be clipped.
- Text is typed with `wtype`. If you are still holding `SUPER` when it arrives, the letters may trigger your binds.
- No realtime mode: text appears after you let go, not while you speak.

## License

MIT, see [LICENSE](LICENSE).

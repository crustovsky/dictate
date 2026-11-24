-- Hold to talk: press starts recording, release stops, transcribes and types.
-- SUPER + D sends the audio to ElevenLabs, SUPER + SHIFT + D keeps it on the NPU.
-- Always exec_cmd, never a Lua callback: callbacks run on the compositor's event
-- loop and the script waits on the network.
-- Both releases call the same stop, so letting go of SHIFT first still ends the recording.
-- Full path: Hyprland's PATH has no ~/.local/bin.
local dictate = os.getenv("HOME") .. "/.local/bin/dictate"
hl.bind("SUPER + D", hl.dsp.exec_cmd(dictate .. " start cloud"), { description = "🎙️ Dictate (cloud)" })
hl.bind("SUPER + D", hl.dsp.exec_cmd(dictate .. " stop"), { release = true })
hl.bind("SUPER + SHIFT + D", hl.dsp.exec_cmd(dictate .. " start local"), { description = "🎙️ Dictate (local NPU)" })
hl.bind("SUPER + SHIFT + D", hl.dsp.exec_cmd(dictate .. " stop"), { release = true })

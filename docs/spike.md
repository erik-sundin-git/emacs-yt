# M0 spike: findings

These are checks of the plan's assumptions against the real tools, run on 2026-11-01 with the flake's pinned nixpkgs (`fa1373130d5a`, nixos-26.05): mpv 0.41.0, yt-dlp 2026.10.21, Emacs 30.2.

## mpv JSON IPC (`--idle=yes --vo=null --ao=null`, `av://lavfi:testsrc` input, no network)
| Question | Result |
|---|---|
| Does named `loadfile` inside `command` work? | **Yes.** `{"command":{"name":"loadfile","url":U,"flags":"replace","options":{"force-media-title":"Tést title","start":"12.5"}},"request_id":2}` → `{"data":{"playlist_entry_id":1},"request_id":2,"error":"success"}`. The title (with UTF-8) and the start time were both applied: `time-pos` read 13.4 shortly after. |
| Must option values be strings? | **Yes.** `"options":{"start":12.5}` → `"error":"invalid parameter"`. |
| Is the top-level `{"name":"loadfile",…}` form accepted? | **No**, it returns `"invalid parameter"`. Named arguments are only accepted as the value of `command`. |
| A bare `["quit"]` line? | **Ignored.** It is not a JSON IPC message, and mpv kept running. Always use `{"command":["quit"]}`. |
| Which events carry `playlist_entry_id`? | `start-file` → `{"event":"start-file","playlist_entry_id":1}`; `end-file` → `{"event":"end-file","reason":"stop","playlist_entry_id":1}`; `get_property playlist` entries have `"id":1`. |
| `property-change` while the value is unavailable? | The `data` key is **missing**: `{"event":"property-change","id":1,"name":"time-pos"}`. |
| `get_property` for an unavailable property? | `{"request_id":13,"error":"property unavailable"}` (e.g. `duration` while idle). |
| `playlist-next weak` at the end of the playlist? | `"error":"error running command"`. This must be silenced for navigation. |
| `stop keep-playlist`? | Keeps the playlist (`playlist-count` 1), sends `end-file` with reason `stop`, then `idle`. `idle-active` becomes `true`. |
| Is the socket removed when mpv quits? | **No.** `mpv.sock` (mode 0600) stays behind after a clean quit. yt must delete it, as planned in §7.2. |
| `--wayland-app-id`, `--ytdl-raw-options`, `--script-opts`, `--input-ipc-server` | All present in `mpv --list-options`. `--ytdl-raw-options` and `--script-opts` are key/value lists, so `-append` adds one pair. |

## Host environment
- **Host `LD_LIBRARY_PATH` breaks the flake's mpv.** The interactive shell exports `LD_LIBRARY_PATH=…alsa-lib-1.2.16.1/lib`. That library is built against a newer glibc, so mpv from the flake's nixpkgs dies with `GLIBC_2.43 not found`.
  - The dev shell (`shellHook`) and `nix run .#sandbox` now unset it.
  - The Emacs daemon (pid 2585) does **not** have `LD_LIBRARY_PATH`, so mpv started from the host Emacs is not affected.
- **The sandbox must keep the real `XDG_CONFIG_HOME`.** yt-dlp finds Chromium's profile through `XDG_CONFIG_HOME` (`~/.config/chromium`). The sandbox therefore redirects only `XDG_STATE_HOME` and `XDG_CACHE_HOME`, and sets `yt-runtime-directory` itself. This differs from PLAN §11, which listed `XDG_CONFIG_HOME` among the redirected directories.

## yt-dlp
- `--print urls` with `-f 'bv*[height<=360]+ba/b'` on a public video (no cookies) prints **two lines**, the video stream and then the audio stream, both on `*.googlevideo.com`, and exits 0. This confirms the VLC plan in §7.3 (`V` plus `--input-slave=A`).

## Still pending: these need the dedicated Chromium profile
1. Create the profile `emacs-yt` in Chromium and sign in to YouTube in it. At the time of the spike only `Default` ("Work") existed.
2. `yt-export-cookies --profile "<dir>" --output …`: which keyring wins (gnomekeyring or basictext), the cookie count, and zero decrypt failures.
3. `yt-dlp --cookies <copy> --flat-playlist -I 1:3 -J -- :ytsubs` returns entries. Record which fields are present in them.
4. One mpv play of a real video in the sandbox, with `--ytdl-raw-options-append=cookies=…` and `ytdl_path`, on sway.

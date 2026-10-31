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

## Cookie export (dedicated profile `emacs-yt` = `Profile 1`)
- `yt-export-cookies --profile "Profile 1" --output .sandbox/state/yt/cookies.txt` returned `{"keyring":"GNOMEKEYRING","count":24,"total":55,"decrypt_failures":0,"has_login_info":true,"has_sapisid":true}`. The file is mode 0600, and every kept cookie is on `.youtube.com`. gnomekeyring succeeded on the first try.
- **Expiry bug fixed:** yt-dlp passes Chromium's `expires_utc` (microseconds since 1601) through unchanged (`cookies.py:384-392`), so every cookie looked like it would expire in the year 4×10⁸. The exporter now converts these values to Unix seconds. After the fix, the latest expiry is 2027-12-05.

## Subscription feed (`:ytsubs`, per-run cookie copy, `-I 1:30`, `youtubetab:approximate_date`)
- Exit 0, 30 entries, empty stderr, about 6 s including `nix develop` start-up.
- **Fields present** (non-null, out of 30): id, url (all `/watch?v=`), title, channel, uploader, thumbnails 30. channel_id, channel_url, uploader_id, duration, timestamp, upload_date 29. live_status 3 (1 `is_upcoming`, 2 `was_live`).
- **`view_count` was absent in all 30 entries.** PLAN §2 / §4.3 assumed it was "sometimes" present. The Views column and views-based logic must treat it as optional and usually missing.
- **The approximate timestamps are not monotonic in feed order** (e.g. `…404800` comes before `…444400`), because they are rounded from "N hours/days ago". The feed's **position** must be the primary sort key, with the timestamp used for display only. This changes PLAN §2 and §6.
- **yt-dlp rewrote the cookie copy** (3796 → 3739 bytes, mode stays 0600). `SIDCC`, `__Secure-1PSIDCC` and `__Secure-3PSIDCC` got new expiries and values, and `PREF` was rewritten. This confirms that write-back from the per-run copy (PLAN §4.2) is required.

## Playback: mpv's ytdl_hook cannot play YouTube (root cause found)
- **Symptom:** plain mpv (`--no-config`, no yt options at all) fails on every try with `ffmpeg/warn: https: HTTP error 403 Forbidden`, then `end-file reason=error file_error="no audio or video data played"`. The yt options and cookies are not involved.
- **Cause:** yt-dlp now gives each format an `available_at` timestamp 3–5 s in the future (`extractor/youtube/_video.py:3593`).
  - A request before that time gets **403**; the same URL after it gets **206**. This was confirmed 3/3: `immediate=403 after-available_at=206`.
  - yt-dlp's own downloader waits for it (`[download] Sleeping 5.00 seconds as required by the site...`, `downloader/common.py:468`).
  - mpv's ytdl_hook does not wait, and fetches the URL immediately.
  - Some earlier tests seemed to show that the yt-dlp flags mattered. They did not: the URL fetched last in each round was simply the one fetched before its `available_at`.
- **What works:** Emacs-style resolution, verified on sway:
  1. `yt-dlp --cookies <per-run copy> -f 'bv*[height<=720]+ba/b' -j --no-playlist -- URL` (no warnings).
  2. Wait until `max(requested_formats[].available_at)`.
  3. Send `loadfile` to mpv started with `--ytdl=no`, using options `audio-file`, `force-media-title`, `user-agent` (from `http_headers`) and `end`.

  Result: `start-file → file-loaded → playback-restart → end-file reason=eof`, mpv exit 0.
- **The same delay applies to VLC:** `--print urls` gives the URLs but not `available_at`, so VLC would also get 403. VLC must resolve with `-j` and wait in the same way.

## Plan changes adopted from this spike (applied to PLAN.md §7)
1. **mpv no longer uses ytdl_hook.** mpv runs with `--ytdl=no`, Emacs resolves every video with yt-dlp, and the cookie snapshot for mpv, the `--ytdl-raw-options`, the `ytdl_path` script-opt and the ytdl_hook log ring are all dropped. Emacs now sees yt-dlp's stderr for every playback, so the §4.5 classifier also covers playback errors.
2. **One shared resolver** (`yt-ytdlp-resolve`) for mpv and VLC. It returns the video and audio URLs, the HTTP headers, `available_at` and the title, and the backends start playback from a timer once `available_at` has passed, without blocking Emacs.
3. **Stream URLs expire after about 6 h,** so for long queues an entry whose `end-file` reason is `error` gets re-resolved once.
4. **The feed is sorted by feed position;** timestamps are for display only. `view_count` is optional.

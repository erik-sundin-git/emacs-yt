# Developing yt

## Builds and tests

All builds and tests use the Emacs from this flake, not the Emacs installed
on the host, and run with `HOME` and the XDG directories in a temporary
directory, so they cannot touch real cookies, caches or customizations.
yt-dlp, the cookie exporter, mpv, VLC and curl are replaced by scripted
fakes in `test/bin`; the tests use no network.

```sh
nix develop            # a shell with the test Emacs, mpv, yt-dlp, VLC, jq and curl
make all               # compile, load-check, checkdoc, lint, test (inside nix develop)
make test SELECTOR='"yt-feed-.*"'   # a subset of the tests
nix run .#test         # the same as `make test`, without entering the shell
nix run .#test -- lint # any make target
nix flake check        # every check, plus the tests with compiled code
YT_LIVE=1 nix run .#smoke  # a few checks against the real YouTube
```

`make` refuses to run unless `YT_EMACS` points at the flake's Emacs.

`nix run .#smoke` is the only thing that talks to YouTube.  With the
sandbox's sign-in, it checks the yt-dlp version, the session, five feed
entries and the fields yt reads from them, one stream and SponsorBlock, and
prints counts only.  It changes nothing in the account, and refuses to run
without `YT_LIVE=1` or under CI.

## The sandbox Emacs

```sh
nix run .#sandbox
```

This opens a GUI Emacs that is separate from the host Emacs and its daemon:
an otherwise unconfigured Emacs with yt loaded.  It starts with
`-q --no-site-file`, so it reads none of the host's configuration
(`~/.emacs.d`, `~/.emacs`, `default.el`, the Nix profiles' `site-lisp`).
Its only configuration is [sandbox/init.el](../sandbox/init.el), which loads
yt from the working tree with generated autoloads and binds `C-c y` to
`yt-map`.

Emacs keeps its own files in `.sandbox/emacs.d`.  yt keeps its state (the
sandbox's cookies included), cache and runtime files in the `yt-sandbox`
directories of `$XDG_STATE_HOME`, `$XDG_CACHE_HOME` and `$XDG_RUNTIME_DIR`.
They are outside the checkout, so that no build, archive or search of the
repository picks up the cookies; the sandbox refuses to start on the host
yt's state.  The flake's mpv, yt-dlp, VLC, curl and `yt-export-cookies`
come first on `PATH`.

## Modules

The files are flat at the repository root; the tests are in `test/`.

| File | What it does |
|------|--------------|
| `yt.el` | Package header. All `defgroup`/`defcustom` definitions. Defines `yt-map` and `yt-player-map` (`defvar-keymap`). The `yt` command, which calls `(require 'yt-feed)` in its body. `yt-state-directory` / `yt-runtime-directory` helpers. |
| `yt-process.el` | Generic async process runner: pipe I/O, separate stderr, JSON/NDJSON parsing, timeouts, cancellation, single-flight, and a small counting queue. Knows nothing about YouTube. |
| `yt-video.el` | `yt-video` struct, JSON→struct conversion, formatting of ages and durations, the `yt--now` clock seam. Pure functions. |
| `yt-ytdlp.el` | yt-dlp argv builders and the ordered error classifier (`yt-ytdlp-error-patterns` defconst). Version check. |
| `yt-auth.el` | Profile selection, calling the exporter, the master cookie file, per-run cookie copies and write-back, auth state, `yt-login` / `yt-check-auth` / `yt-logout`. |
| `yt-cache.el` | SQLite store (WAL, busy timeout). `yt-mark-watched` and `yt-watched-changed-functions`. Persistent state such as the chosen profile. |
| `yt-feed.el` | `yt-feed-mode`: the subscription feed, channel uploads, playlists and search results, on tabulated-list. Filters, refresh, thumbnails, the visit marker. |
| `yt-list.el` | What the lists share: the `yt-feed-*` faces, columns that fit the window, `yt-list-mode` (the base of the channels, playlists and history lists: header line, empty message, filter, fetch state), and the loader of yt-select's embark and marginalia glue. |
| `yt-channels.el` | `yt-channels-mode`, the subscribed channels. |
| `yt-playlists.el` | A channel's playlists and the saved ones. |
| `yt-history.el` | The played videos. |
| `yt-info.el` | `yt-info-mode` video detail buffer, with chapters and SponsorBlock segments. |
| `yt-player.el` | Backend generics, `yt-play` / `yt-enqueue`, the stream cache, sequences and shuffle, player commands, `yt-player-mode` (mode-line segment), the queue buffer (mpv's playlist, called the playlist until 0.3.0). |
| `yt-mpv.el` | mpv backend: spawn, IPC, events, watched and resume tracking, chapters, SponsorBlock skipping. |
| `yt-vlc.el` | VLC backend. |
| `yt-sponsorblock.el` | SponsorBlock segments, fetched with curl by hash prefix. |
| `yt-subscribe.el` | Subscribing through YouTube's internal API with curl. |
| `yt-url.el` | Strict parsing of YouTube links and `yt-url-handler-mode` for `browse-url`. |
| `yt-org.el` | `org-store-link` for the video at point, as a plain YouTube link; loaded by the user with org's `ol`. |
| `yt-thumbs.el` | Thumbnails, downloaded with curl. |
| `yt-select.el` | `yt-select-video` completing-read (category `yt-video`). Optional marginalia and embark glue, registered through `after-load-functions` (package-lint rejects `with-eval-after-load`). |
| `yt-doctor.el` | `yt-doctor` diagnostics buffer. |
| `bin/yt-export-cookies.py` | The cookie exporter, a small Python script on top of yt-dlp. |
| `bin/yt-remote` | Runs a player command in the running Emacs, through emacsclient. |

**No external elisp dependencies.**
- empv and mpv.el were rejected: empv brings its own Invidious UI and global state, and mpv.el uses the legacy `json` library and `tq`.
- yeetube, ytdious, and elfeed-tube only do search or RSS, not authenticated feeds.
- The Commentary credits empv and mpv.el as prior art. If any code is adapted from them, their GPL copyright notices are kept.

**Dependency graph** (downward; checked by `make load-check`, which loads and compiles each file alone). `yt-auth-run`, which runs yt-dlp with a private cookie copy, lives in `yt-auth`; `yt-ytdlp` keeps only argument lists, the error classifier and the version check.

```
yt-select ─> yt-info, yt-playlists ─> yt-feed ─> yt-player ─> yt-auth ─> yt-ytdlp ─> yt-process
yt-channels, yt-subscribe ─> yt-feed         │      │    └─> yt-cache ─> yt-video
yt-history, yt-doctor ─> yt-player           │      ├─> yt-list ─> yt-video
yt-mpv, yt-vlc ─> yt-player                  │      └─> yt-url ─> yt-video
yt-mpv, yt-info ─> yt-sponsorblock ─> yt-process
yt-feed ─> yt-thumbs ─> yt-process
yt-org ─> yt-video, and org's ol
every module ─> yt (customs and keymaps); yt.el requires only xdg
```
A few calls go the other way, lazily: yt-player loads a backend (`yt-mpv` or `yt-vlc`) by its symbol; the feed's `+`/`-` load yt-subscribe; yt-list loads yt-select from a timer once embark or marginalia is loaded; yt-url loads yt-player or yt-feed when it opens a link.

## History

[history/](history/) keeps the original implementation plan (milestones
M0-M7), the spike that preceded it, and the improvement plan (M8-M15),
with their reviews.  They record why things are the way they are; the code
is authoritative where they differ.

# yt improvement plan

Written 2026-11-02/03 against commit 584782d.  Ten planners each wrote
one section (reliability, performance, UX and keys, playback,
discovery, privacy and security, testing and CI, architecture,
packaging, integration); the merged draft (about 80 items in 10
phases) was then reviewed by ten judges (factual accuracy, value for
the user, scope, sequencing, regression risk, privacy of new
features, Emacs idioms, testability, YouTube/yt-dlp/mpv realism,
effort and blind spots).  This is the revised plan: about 40 items in
eight milestones, continuing the numbering of docs/PLAN.md (M0-M7).
What the judges changed is summarized at the end.

Effort: S (under half a day), M (a day or two), L (more).
`file:line` references are at 584782d.

## Progress

- **M8, M9 and M10: done** (2026-11-03), commits e2e5841 to a267a54, each
  with tests and a green CI run.  Found on the way: `yt-cache.el` used
  `cl-struct-slot-value` without cl-macs at run time (caught by the new
  load check), and a test that raced on busy CI runners.
- **M11-M15: not started.**  Review the plan again before going on.

## Guiding decisions

1. **Ship something visible every few commits.**  Bugs that hit
   everyday watching come first, interleaved with cheap visible
   improvements; refactors happen only where a feature needs them.
2. **A size ceiling.**  The package is about 7,200 lines of Elisp and
   29 options in yt.el.  Stay under about 8,500 lines and 35 options;
   a new option must have a real use.
3. **No new requests to YouTube without a limit**, and no new use of
   YouTube's internal API (subscribe stays the only one).
4. **State must survive a rollback.**  A Home Manager rollback reverts
   the code but not ~/.local/state/yt: cache and cookie formats stay
   readable by the previous version, and anything that touches them
   gets a "State changes" note in the CHANGELOG.
5. **Definition of done.**
   - Bug fix: the regression test comes first and fails on the parent
     commit; an existing test that encoded the bug is named in the
     commit message.
   - Refactor: no test changes except renames; interpreted, compiled
     and per-file load checks green.
   - Feature: tests for the happy path and an error path, README,
     CHANGELOG, `:package-version`; anything that depends on real
     YouTube behaviour is also checked by hand in the sandbox (counts
     only), and says so.
   - Security: the test asserts the negative (no `Cookie:` or stream
     URL in `*yt-log*` or `*Messages*`).
   - Each item: `make all`, `nix flake check`, commit, push, dotfiles
     lock update.

## M8: watching just works (about 3 days)

- **8.1 CI and a per-file load check (S).**  GitHub Actions runs
  `nix flake check -L --keep-going` on push and PR, with
  `permissions: contents: read`, actions pinned by SHA, no secrets.
  `make load-check` (also a flake check) loads and compiles each file
  in its own `emacs -Q`: today all files compile in one process
  (Makefile:31-33) and the test helpers require most modules, so a
  missing `require` is invisible.  It also regenerates the stale local
  yt-autoloads.el.
- **8.2 `yt-forget-history` lost its autoload (S, bug).**  The
  `;;;###autoload` cookie at yt-cache.el:449 now precedes a section
  comment, so the packaged build (autoloads regenerated, flake.nix:43)
  autoloads `yt-cache-add-history` and not `yt-forget-history`, which
  the README tells users to run with M-x.
- **8.3 Bot-check pause never lifted early (S, bug).**  The backoff is
  set (yt-auth.el:283, yt-subscribe.el:246) and only expires by itself,
  even after a successful `yt-login` (whose check ignores the backoff,
  yt-auth.el:439).  Clear it when `yt-login` succeeds, not on any `ok`
  state (a verify run ignores the backoff); show "Paused until HH:MM
  (bot check)" in the feed header.
- **8.4 Empty output taken for an expired session (S, bug).**
  `yt-auth--empty-result-p` (yt-auth.el:285-291, 351) treats a
  successful run with no entries as `expired`: a yt-dlp extractor
  regression or an account with no subscriptions triggers a cookie
  re-export (keyring prompt), a retry, then "session expired".  After a
  fresh export, an empty result is reported as "YouTube returned no
  videos (yt-dlp may need updating)", not as expired.
- **8.5 Refreshes and downloads that never finish (S-M, bug).**
  - An error in `yt-auth--write-back` skips both callbacks
    (yt-auth.el:355-361); an error in `yt-cache-put-feed` leaves
    `yt-feed--refreshing` set (yt-feed.el:619-630), and `g` then refuses
    (`G` recovers).  Write-back is opportunistic: wrap it and log; wrap
    the feed's success path so any error ends in `yt-feed--fail`.
  - Thumbnail `finish` can signal before `done` (yt-thumbs.el:96-102);
    after four such errors the queue (limit 4) is stuck.
    `unwind-protect` around `done`, also in the info buffer.
  - A signal inside `yt-auth-export` after the waiter is pushed
    (yt-auth.el:199) leaves the export "running" forever; one failing
    waiter drops the rest (the list is cleared first, :185).  Protect
    the start and each waiter.
  - A timeout part-way through a feed discards the videos already
    received (yt-feed.el:664-668): merge them as a non-full refresh.
- **8.6 mpv: retries, live streams, lost connections (M, bugs).**
  - `yt-mpv--retry` reloads with `replace` (yt-mpv.el:455), emptying
    mpv's playlist.  After an error mpv has already moved to the next
    entry, so retry in place: find the failed entry's index, `loadfile
    … insert-at` with `:index` and the position, then
    `playlist-play-index`.  One helper, with a start position and
    "finalize the old entry", reused by 13.1.
  - Positions are saved and resumed for live streams (yt-mpv.el:430;
    yt-player.el:345-355 does not check).  Carry `:live` from `is_live`
    only (`was_live` videos need resume most); never save or resume a
    position for them; retry without `start`.
  - The reconnect counter is reset only at start and exit
    (yt-mpv.el:125), so after three disconnects yt silently stops
    reconnecting while commands pile up (216); when one reconnect's
    connect attempts fail, the playing mpv is killed (234-240, 254);
    signal exits are not logged (508).  Reset on connect; never kill a
    playing mpv on a failed reconnect ("lost control of mpv; Q quits
    it"); before starting a new mpv, kill an old one that is alive but
    unconnected; log signal exits.
- **8.7 History shows stale progress; reprints too often (S, bug).**
  At end-file the history refresh runs before `yt-mpv--finalize`
  (yt-mpv.el:464 vs 483) and `yt-cache-set-position` runs no hook, so
  the Progress column is stale.  Run `yt-history-changed-hook` from
  `yt-cache-set-position`; debounce the refresh (it runs 3-5 times per
  start/end, about 40 ms each, yt-history.el:208-210); when the buffer
  is not shown, mark it dirty and reprint when shown; a hash of played
  times instead of a `seq-find` per sort comparison (91-99).
- **8.8 Thumbnails after a network outage (S, bug).**  Failures are
  remembered for the session (yt-thumbs.el:99-100, 119).  Store the
  failure time; retry after 10 minutes (compared with `yt--now`, not a
  timer) and after a successful refresh.  The test
  `yt-thumbs-failure-leaves-nothing-and-is-not-retried` changes on
  purpose.
- **8.9 Embark on rows does nothing until `C-c y f` (S, bug).**  The
  target finder registers only when yt-select loads
  (yt-select.el:185-216).  Create `yt-list.el`, required by every list
  mode, holding the registration (it grows in M12).
- **8.10 Wrong empty-feed hint (S, bug).**  "Press C to clear it"
  appears for any filter, including hide-watched/Shorts/upcoming,
  which `C` does not clear (yt-feed.el:272-277, 414-415, 797).  Build the
  message from the filters that are on, with
  `substitute-command-keys` and `\\<yt-feed-mode-map>`; "No results for
  “q”" for searches.
- **8.11 The Nix package finds the exporter by itself (S).**
  `yt-export-cookies-program` is a bare name (yt.el:166), so the
  daemon depends on its unit's PATH.  The flake patches in the store
  path; the "not found" message stops telling users to use the sandbox
  (yt-auth.el:159-160).  The Home Manager module gains
  `programs.yt.swayWindowRule` (floating, sticky, sized; your sway has
  no rule for `app_id emacs-yt`), enabled in the dotfiles.
- **8.12 Version 0.2.0 (S).**  `Version: 0.2.0`; the five options added
  after M7 get `:package-version '(yt . "0.2.0")`; CHANGELOG sections
  `0.2.0` and `0.1.0`; the version read from yt.el in the flake (now
  repeated at flake.nix:29, 36, 41); `yt-version` first in
  `yt-doctor`.  No tags or pinning unless you want them (decision 5).

## M9: visible wins (about 3-4 days)

- **9.1 Columns that fit the window (M).**  Title is fixed at 70
  columns (yt-feed.el:848, yt-player.el:871), so Age and Dur fall off
  half-width sway tiles.  A pure `yt-list-column-widths WIDTH`
  (tested at 60, 100, 200) from `window-max-chars-per-line`, recomputed
  from a buffer-local `window-size-change-functions` through a short
  timer, only when the width changes; the selected window wins when the
  buffer is in several.
- **9.2 New since last visit (S, no requests).**  `fetched_at` is kept
  from a video's first fetch (yt-cache.el:215, 226-232).  "Last visit"
  is when `yt` last showed the subscription feed, kept in `meta`.
  Rows fetched since then get a distinct marker (● already means
  unwatched, yt-feed.el:102, 327); the header says "N new since 3h
  ago"; `t n` shows only new ones.
- **9.3 Mark all shown as watched, `W` (S).**  Binds the unbound
  `yt-feed-mark-all-watched` (yt-feed.el:716): asks with the count, and
  `u` right after undoes the batch.
- **9.4 Keep resolved streams in memory (M).**  Every play runs
  `yt-dlp -j` again (2-5 s).  Keep id+format+cookie generation →
  streams, valid until the earliest `expire=` of the video and audio
  URLs (yt-dlp does not parse it, so yt does) minus a margin; never for
  live or upcoming videos or URLs without `expire`; mpv only (VLC has
  no retry); the mpv retry evicts the entry and resolves fresh.
  Memory only: never in SQLite, logs, bookmarks or links; cleared on
  `yt-logout`.  Replaying or resuming a recent video then starts in
  about a second.  The `available_at` margin stays (yt-dlp rounds to
  whole seconds; the wait only matters with ads).
- **9.5 Play all from here, `A` (S).**  The shuffle sequencer
  (yt-player.el:449-537) becomes `yt-player-play-sequence VIDEOS NAME
  &optional SHUFFLE`; `A` plays the unwatched shown videos from point
  down, two resolved ahead.
- **9.6 Chapters in mpv (S-M).**  mpv runs with `--ytdl=no`
  (yt-mpv.el:141), so it never gets chapters, though the resolve JSON
  has them (yt-ytdlp.el:132 drops them).  Keep them; on `file-loaded`
  (which has no entry id: use the entry of the last `start-file`) set
  `chapter-list`, as mpv's own ytdl hook does; `C-c y .`/`,` for
  next/previous chapter, repeatable; the chapter in the mode line.
- **9.7 YouTube links anywhere open in yt (M, opt-in).**
  `yt-url-handler-mode` adds a predicate to `browse-url-handlers`
  (after `(require 'browse-url)`):
  - parse the URL; allow only www/m/music.youtube.com, youtu.be and
    youtube-nocookie.com, no userinfo or port; rebuild the canonical
    URL from the validated 11-character id, never hand the raw URL to
    yt-dlp; drop `si=`, `pp=`, `feature=`; `t=`/`start=` (also
    `1m30s`) as a bounded integer, also used by `yt-play-url`
    (yt-video.el:127 drops it today);
  - videos play, playlists and channels open in yt;
  - one `yt-browse-url` wrapper for yt's own four "open in browser"
    commands (yt-player.el:752, yt-info.el:163, yt-channels.el:207,
    yt-playlists.el:214) bypasses the handler and checks the YouTube
    prefix (this also closes the positional-URL finding);
  - `C-u` opens the real browser; a failure falls back to it;
  - documented: notmuch and org links work at once; eww only for URLs
    matching `eww-use-browse-url`; with `yt-player-youtube-history` on,
    a clicked link reaches your YouTube history.

## M10: process, curl and auth core (about 4-5 days)

- **10.1 Test harness (M-L).**
  - Per-module reset functions that `yt-test-with-scenario` calls (it
    misses the player queue, shuffle and wait timer,
    `yt-select--videos`, `yt-vlc--process`, the info and thumbnail
    queues and several hooks, test/yt-test-helpers.el:229-278).
  - Every program variable points at a tripwire fake that fails the
    test when run (the doctor test runs the real `mpv --version` today,
    yt-doctor.el:116-117); `scripts/isolated` unsets
    `DBUS_SESSION_BUS_ADDRESS`, `DISPLAY` and `BROWSER`.
  - Teardown asserts no yt processes, timers, `*yt…*` buffers or yt
    functions on global hooks remain.
  - Fakes: fake-curl gets a lock, `NN.exit`, `NN.hang` and exits 2 unless
    its first argument is `--disable`; fake-export-cookies gets a hang
    mode; the fake mpv server gets a playlist model and a disconnect.
  - Timing: `yt-player-waits-for-release` and eight negative assertions
    after fixed sleeps wait for a positive sync point first.
- **10.2 The process contract (M, in three commits).**
  1. Reproduce: a test that overflows `max-lisp-eval-depth` with many
     queued jobs that finish synchronously, uncompiled, and ordering
     tests for today's sentinels (stderr closing before or after exit,
     the stderr grace path, cancel while finishing).
  2. Contract: `yt-process-run` returns non-nil exactly when a callback
     will follow.  A missing program already delivers `on-error`
     (yt-process.el:157-162) and now returns non-nil; a busy key still
     returns nil with no callback.  No caller changes, and the double
     completion in SponsorBlock and thumbnails goes away; SponsorBlock
     stops calling its callbacks synchronously (yt-sponsorblock.el:151).
  3. The queue starts the next job from a timer instead of recursing
     through `done` (yt-process.el:96-105).  Deferring `finish` out of
     sentinels happens only if step 1 shows the nested sentinels are a
     real cause.
- **10.3 One curl helper (S).**  Three call sites build curl arguments
  and two parse the status line (yt-sponsorblock.el:136-163,
  yt-subscribe.el:137-148, 199-220, yt-thumbs.el:102-118).
  `yt-process-curl` always passes `--disable` first (curl reads
  `~/.curlrc` otherwise; with `verbose` there, subscribe's failure
  path would show `Cookie:` and `Authorization:` lines in a prompt and
  `*Messages*`), `--proto =https --proto-redir =https`, no `-L`, `--`
  before the URL; secrets only in a 0600 config file; stderr scrubbed;
  returns `(STATUS . BODY)`.  A 200 with malformed JSON is a failure,
  not "no segments" for the session (yt-sponsorblock.el:161-163).
- **10.4 Cookie handling (M).**
  - `yt-auth-with-cookie-copy`, used by yt-dlp runs and subscribe,
    owns the copy and its cleanup (subscribe leaks the copy and config
    if `read-sid-cookies` or `write-config` signals,
    yt-subscribe.el:182-187).  Public `yt-auth-set-state` and
    `yt-auth-backing-off-p` replace the private calls from subscribe and
    doctor.
  - One sweep of leftover files (cookie copies, `curl-*.conf` holding a
    SAPISIDHASH, state-dir `.cookies-*` from a failed write-back, dead
    mpv sockets), older than an hour, at first use, login and logout
    (the current sweep covers only copies, yt-auth.el:218-227).
  - Write-back skips runs that timed out, were cancelled or were killed
    (not runs stopped early: an incremental refresh stops early by
    design, yt-feed.el:661, and must keep rotating cookies); keeps
    `cookies.txt.prev`; accepts a copy only if it has every login cookie
    the master has; keeps only youtube.com lines (including
    `#HttpOnly_.youtube.com` lines, with the Netscape header), then
    validates again.
  - The export gets its own 30 s timeout (a bindable variable) and a
    "timed out: is the keyring locked?" message instead of "yt-dlp
    failed without an error message" (yt-auth.el:177-180).
  - The extra-args denylist (yt-ytdlp.el:41-57) also rejects
    abbreviated long options and clustered short flags.
- **10.5 Logs and minibuffer histories (S, privacy).**
  - Redaction moves into `yt-process-log` (yt-process.el:63), so every
    `*yt-log*` line drops stream and timedtext URLs, `SAPISID*HASH`,
    `Cookie:` and `Authorization:`; the log is capped.
  - A latency trace (ids and timestamps only) for resolve, available-at,
    loadfile and start-file.
  - Search queries, the completion history of video titles and the
    `yt-play-url` prompt are saved in plain text by savehist
    (yt-feed.el:1076, yt-select.el:58, yt-player.el:369), contradicting
    the README.  yt adds them to `savehist-ignored-variables` unless
    `yt-save-minibuffer-history` is set.
  - The doctor shows the profile directory, not its display name (often
    the owner's real name, yt-auth.el:118-123), and says its output is
    safe to paste.
- **10.6 Sandbox state out of the source tree (S, privacy).**  The
  sandbox keeps its cookies in `$repo/.sandbox/state`
  (flake.nix:170-175); git ignores it, but `nix build path:.` copies
  ignored files into the world-readable store.  Use
  `$XDG_STATE_HOME/yt-sandbox` and `$XDG_CACHE_HOME/yt-sandbox`; never
  move old files automatically (print how); refuse if that directory
  is the real `yt-state-directory`.
- **10.7 A small live smoke test (M).**  `nix run .#smoke` with
  `YT_LIVE=1`, refusing under `CI`, sandbox state only (asserted),
  `yt-player-youtube-history` forced off, counts only: yt-dlp version,
  auth state, feed entries, resolve fields present, and which JSON keys
  that yt reads are missing from real output (a list kept in the tests).

## M11: cache safety (about 2-3 days)

- **11.1 Backups and rollback safety (S-M).**  `yt-cache-backup`
  (`VACUUM INTO` a dated file), also run automatically before any
  migration.  A `min_reader` schema version in `meta`: purely additive
  migrations keep older versions able to open the cache, instead of
  the "written by a newer yt" error (yt-cache.el:115-116).  Fixture
  databases for each old schema, with their data asserted after
  migration.
- **11.2 A damaged cache (M).**  `yt-cache--open` re-signals every error
  (yt-cache.el:119-121) and one bad row fails a whole feed load (165).
  Recognize corruption by SQLite's error codes (not message text; a
  locked or newer database is not corrupt); then copy, never move, the
  db with its `-wal`/`-shm`, and offer `yt-cache-reset`, which first
  salvages watched marks, positions, history and saved playlists into
  the fresh database.  Undecodable rows are skipped one by one.  The
  doctor runs `PRAGMA quick_check`.
- **11.3 Pruning (S-M).**  Nothing is ever deleted from `videos`; feeds
  of visited channels keep up to 500 rows; `refreshed:` keys pile up;
  the thumbnail directory is never cleaned.  An idle `yt-cache-gc`
  removes videos older than 90 days that are in no feed, history or
  saved playlist and have no watched mark or position, stale meta keys
  and old thumbnails; an occasional `VACUUM`; sizes in the doctor.
- **11.4 Forgetting really forgets (S).**  `PRAGMA secure_delete=ON`, and
  `wal_checkpoint(TRUNCATE)` after `yt-forget-history` or clearing the
  history (WAL mode keeps old rows otherwise, yt-cache.el:111).
- **11.5 Unwatched counts in one query (S).**  The saved playlists
  decode up to 300 videos per row on every print
  (yt-playlists.el:73-76, 87); one `GROUP BY` query, the same for the
  channel stats (yt-channels.el:79-92).

## M12: lists and keys (about 3-4 days; needs decisions 1-2)

- **12.1 Snapshot tests first (S).**  Buffer text and header line of the
  feed, channels, playlists, history and queue, with a fixed clock and
  width, before anything moves.
- **12.2 A shared list base (M).**  `yt-list.el` (from 8.9) gets the
  `yt-feed-*` faces (names kept), the header and empty-message
  helpers, `yt-channel-page-url` (the format string is repeated,
  yt-feed.el:985, 995, yt-channels.el:76) and a buffer-local
  `yt-channel-at-point-function` (replacing the `fboundp` reach into
  yt-channels, yt-feed.el:51, 999).  History, channels and playlists
  derive from `yt-list-mode` (`:interactive nil`); the feed and the
  queue keep their own code.  Keymaps state their parents explicitly
  (`define-derived-mode` does not override an existing `:parent`):
  `(make-composed-keymap yt-video-actions-map yt-list-mode-map)`.
  Filters use the feed's syntax everywhere (a separate commit, since it
  changes behaviour).  Header lines read buffer-local flags updated
  from the change hooks, not SQLite on every redisplay
  (yt-feed.el:543-549).
- **12.3 Consistent keys (S).**  In every yt list: `j` is all of
  `yt-map` (`j c` = `C-c y c`); `P` the player (channels and playlists
  lack it today, yt-channels.el:232, yt-playlists.el:224); `L`, `G`,
  `C` (clear filters), `b`; `/` filters (`s` stays one release as an
  alias that says so); `o` opens in playlists; `z` shuffles the queue;
  `=` repeats.  Data-changing keys confirm: `D` in history with
  `yes-or-no-p`, unsubscribing as now.  One short hint line per view;
  with no cookies the feed lists the three setup steps.  A test that
  every interactive command is bound, or on an M-x-only allowlist.
- **12.4 The mpv playlist becomes the queue (S, decision 1).**
  `*yt-queue*`, label "queue (mpv)", `define-obsolete-function-alias`
  and `define-obsolete-variable-alias` (with a version) for
  `yt-playlist-mode`, its map, hook and commands.
  `yt-player-file-started-functions` becomes
  `yt-player-started-functions` (new since 0.1.0, so no alias).
- **12.5 Public backend API and docs (S).**  yt-mpv and yt-vlc use
  eight private `yt-player--` functions (yt-mpv.el:517, 520-521;
  yt-vlc.el:93, 102); make them public, add
  `yt-player-backend-exited` and `yt-player-backend-now-playing`
  (needed by 13.2 and 15.1), and document the generics and the command
  vocabulary.  docs/PLAN.md: the module table, the dependency graph,
  the privacy notes (SponsorBlock, subscribe), the promised live tests.

## M13: playback (about 1-2 days)

- **13.1 Audio only (S).**  `M` plays a video as audio, `C-c y M`
  switches the playing one: resolve `bestaudio` and load that URL alone
  (with DASH, `vid=no` would keep the video stream downloading), at
  the current position through the 8.6 helper; ♪ in the mode line.
- **13.2 Mode line (S).**  Chapter, queue position `2/5`, ♪, LIVE, a
  marker when skipping is off, with `char-displayable-p` fallbacks for
  TTY frames.
- **13.3 Fullscreen toggle (S).**

## M14: your account and channels (about 2-3 days)

- **14.1 Watch Later, Liked and your YouTube playlists (M, read-only).**
  yt-dlp's `:ytwatchlater` and `:ytfav` (lists WL and LL) and
  `feed/playlists` (the same shape as a channel's playlists).  A source
  `(account KIND)` (every `pcase` on sources changes: yt-feed.el:168,
  182, 542, 999, 1012); `C-c y a` submap.  An auth source on which empty
  output is fine, with a pattern for "playlist does not exist" as
  expired; the `playlist_channel` fallback (yt-video.el:105-108) off for
  these, or videos get credited to your own channel.
  `yt-forget-history` and `yt-logout` clear them.  Checked by hand once.
- **14.2 Mute channels (S-M).**  An additive `channel_prefs` table (the
  channels table is rewritten on every refresh, yt-cache.el:329), safe
  under 11.1; muted channels hidden from the feed by default, `t m`
  shows them; `M` in the channels list.  Shorts in the feed have no
  channel, so muting cannot hide them.
- **14.3 Streams and Shorts tabs (S).**  `T` in a channel cycles videos,
  streams and shorts (only `/videos` today, yt-ytdlp.el:84); a missing
  tab is an empty list, not an error.

## M15: notes (about 1 day)

- **15.1 Org links (S-M).**  In `yt-org.el`, which requires `ol` and is
  loaded once org is (through `after-load-functions`): a private link
  type with only a `:store` function, which in yt buffers stores a
  plain `https://www.youtube.com/watch?v=ID` link (your org-roam is
  shared with Logseq), with `&t=N` when that video is playing, and
  "Title — Channel".  Never stream URLs or tracking parameters.
- **15.2 eldoc (S).**  On rows: the full title, channel, exact date and
  resume position (titles are truncated in the columns).

## Deferred

With a reason each; any can come back on request.

- **Transient `?` menu:** a fourth key-discovery layer next to the
  which-key labels, `j` and the hint line.
- **Background refresh and notifications:** needs the feed fetch split
  out of the buffer (L).  If built: opt-in, no cookie export from a
  timer, pause after the first auth or bot-check failure until a manual
  `g`, a count-only notification by default (lock screen), every 30 min
  at most.
- **Group the feed by day** (cosmetic; `tabulated-list-groups` runs the
  entries function twice).
- **Search filters and channel search:** relies on hand-encoded `sp`
  values that YouTube changed in 2025.
- **Bookmarks**, **a quality menu** (beyond audio only), **per-channel
  speed**, **starting mpv during the resolve** (0.2-0.5 s, first play
  only), **thumbnail image cache**, **faster row decoding** (5 ms per
  500 rows), **idle age timer**, **splitting yt-player.el**.
- **Subtitles:** yt-dlp fetches them with browser impersonation and may
  need a PO token; mpv's own fetch would likely fail.
- **Signed-out search:** check in My Activity first whether searches
  are tied to the account.
- **Packaging for others:** README restructure, the exporter without
  Nix, other Chromium browsers and KWallet, package-vc and MELPA.
- **Brand accounts:** subscribe sends `X-Goog-AuthUser: 0` and no
  `X-Goog-PageId` (yt-subscribe.el:128); document it.
- **Two Emacs processes** racing on the cookie file.

## Cut

- Weekly `nix flake update` CI job: nobody triages red runs nobody
  pushed.
- Syncing watched marks from YouTube history: `:ythistory` has no watch
  times, and yt already writes plays to YouTube: two-way sync with no
  source of truth.
- Watch Later writes: no evidence the `edit_playlist` call works, and
  it would be a second internal-API use.
- `--prefetch-playlist`: mpv rarely reads a stream to the end, and the
  audio URL is not prefetched.
- org-protocol, a consult buffer source, embark channel and playlist
  targets, coverage reports, broad hook renames.

## Decisions for you

1. Rename the mpv playlist to "queue" (12.4)?
2. Free `s` so that only `/` filters, keeping `s` one release as an
   alias (12.3)?
3. The browse-url handler (9.7): on by default in your config?
4. Audio only on `M` (13.1)?  (`M` is free in video buffers.)
5. Tags and pinning (8.12): keep following main, or pin the dotfiles to
   release tags?
6. Scope: all of M8-M15 (about 20 working days), or M8-M10 first and
   decide again?

### Taken on 2026-11-03

- Scope: M8-M10 now, then review the plan again before M11-M15.
- The mpv playlist becomes the queue (12.4).
- `/` is the only filter key; `s` stays one release as an alias (12.3).
- The browse-url handler (9.7) is enabled in the user's config.
- No release tags for now; the dotfiles keep following main (8.12).

## What the review changed

- **Facts:** all phase 1 bug claims checked against the code; two
  rewritten (the export waiter leak needs a signal after the push; the
  "double completion" is harmless, the real flaw is synchronous
  callbacks and queue recursion), one upgraded (8.2: the stray
  autoload cookie broke `yt-forget-history` in the package), the
  nested-sentinel theory made a hypothesis to reproduce, several line
  numbers fixed.  One judge's claim that the flake has no Home Manager
  module was wrong (`homeModules.default`).
- **Order:** interleaved visible wins with bug fixes; the curl helper
  absorbs `--disable` and the JSON fix; the cookie-copy helper absorbs
  the leftover-file fix; `yt-list.el` starts with the embark fix; the
  retry helper serves audio only; renames happen before anything is
  released.
- **Risk:** write-back must not skip runs stopped early (that would
  break cookie rotation on every refresh); the cookie filter handles
  `#HttpOnly_` lines; corruption detection uses error codes and copies,
  never moves; the process contract changes without touching callers;
  data-changing keys confirm; schema changes stay readable after a
  rollback.
- **Realism:** the mpv retry uses `insert-at` (insert-next-play lands
  after the entry mpv already moved to); audio only loads `bestaudio`
  rather than `vid=no`; chapters are set on `file-loaded`; eww only
  hands links to browse-url when `eww-use-browse-url` matches; account
  feeds need their own expiry pattern and no `playlist_channel`
  fallback; subtitles, prefetching and Watch Later writes were cut or
  deferred.
- **Idioms:** explicit composed keymap parents, obsolete aliases with a
  version, a private org link type instead of `:store` on "https",
  `window-max-chars-per-line`, `browse-url` required before its
  handlers.
- **Added:** empty output taken for an expired session, cache pruning,
  backups and rollback safety, savehist leaking queries, central log
  redaction, the doctor's display name, a hermetic harness without
  D-Bus or a display.
- **Scope:** from about 80 items to about 40; transient, notifications,
  search filters, bookmarks and packaging for others deferred.

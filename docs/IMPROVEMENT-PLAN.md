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
- **M11-M15: not started.**  Reviewed again on 2026-11-03 (see "Second
  review" at the end): reordered to M12, M11, M14, M13, M15.

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

## Remaining work, as revised on 2026-11-03

The second review (summary at the end) reordered and trimmed M11-M15.
The package is now 8,280 lines of Elisp with 35 options, against the
ceiling of 8,500 lines and 35 options, so what remains must earn its
lines: M12 comes first because it removes more code than it adds, and
four items are deferred or cut.  The new ceiling is 9,000 lines and 37
options; the items below add about 550 lines and two options.

### M12: lists and keys (first; about 1 session)

- **12.1 Snapshot tests first (S).**  Buffer text and header line of the
  feed, channels, playlists, history and queue, with a fixed clock and
  width, before anything moves.
- **12.2 A shared list base (M, about -150 lines).**  `yt-list.el` (which
  now holds the column fitting and the embark loader) gets the
  `yt-feed-*` faces (names kept), the header and empty-message helpers,
  `yt-channel-page-url` (the URL format is repeated in yt-feed.el and
  yt-channels.el) and a buffer-local `yt-channel-at-point-function`
  (replacing the `fboundp` reach from yt-feed into yt-channels).
  History, channels and playlists derive from `yt-list-mode`
  (`:interactive nil`); the feed and the queue keep their own code.
  Keymaps state their parents explicitly (`define-derived-mode` does not
  override an existing `:parent`).  Filters use the feed's syntax
  everywhere, in a separate commit since it changes behaviour.  Header
  lines read buffer-local flags instead of querying SQLite on every
  redisplay.
- **12.3 Consistent keys (S).**  In every yt list: `j` is all of
  `yt-map` (`j c` = `C-c y c`); `P` the player (the channels and
  playlists lists still lack it); `L`, `G`, `C` (clear filters), `b`;
  `/` filters, `s` staying one release as an alias that says so; `o`
  opens in playlists; `z` shuffles the queue; `=` repeats.  `D` in the
  history asks with `yes-or-no-p`.  One short hint line per view; with
  no cookies the feed lists the three setup steps.  A test that every
  interactive command is bound somewhere, or on an M-x-only allowlist.
- **12.4 The mpv playlist becomes the queue (S).**  `*yt-queue*`, label
  "queue (mpv)", obsolete aliases with a version for `yt-playlist-mode`,
  its map, hook and commands; `yt-player-file-started-functions` becomes
  `yt-player-started-functions` (not in 0.1.0, so no alias).
- **12.5 Public backend API and docs (S).**  yt-mpv and yt-vlc still use
  private `yt-player--` functions; make those public, add
  `yt-player-backend-now-playing` (for 13.2 and 15.1), and document the
  generics and the command vocabulary.  docs/PLAN.md now lags further:
  its module table and dependency graph lack yt-list, yt-url, yt-history,
  yt-subscribe and yt-sponsorblock, and its privacy notes lack
  SponsorBlock, subscribing and the curl helper.  README's key tables
  follow 12.3.
- **Release 0.3.0 (S).**  The keys change, so the CHANGELOG's Unreleased
  section (long by now) becomes 0.3.0, with a "Keys that changed" list.

### M11: cache safety (second; about half a session)

- **11.1 Backups and rollback safety (S-M).**  `yt-cache-backup`
  (`VACUUM INTO` a dated file), run automatically before any migration;
  a `min_reader` version in `meta`, so that additive migrations keep an
  older yt able to open the cache instead of "written by a newer yt"
  after a Home Manager rollback; fixture databases of each old schema,
  their data asserted after migrating.  The doctor shows the schema
  version and the file's size.  Needed before 14.2's new table.
- **11.2 A damaged cache (S-M, simplified).**  Recognize corruption by
  SQLite's error codes (a locked or newer database is not corrupt), copy
  the database with its `-wal`/`-shm` aside, start a fresh one, and say
  where the copy and the latest backup are.  No salvage code: 11.1's
  backups cover that.  Undecodable rows are skipped one by one.
- **11.4 Forgetting really forgets (S).**  `PRAGMA secure_delete=ON`, and
  `wal_checkpoint(TRUNCATE)` after `yt-forget-history` or clearing the
  history.
- **11.5 Unwatched counts in one query (S).**  The saved playlists still
  decode every cached video of every playlist on each print; one
  `GROUP BY` query, and the same for the channel statistics.

### M14: your account and channels (third; about 1 session)

- **14.1 Watch Later, Liked and your YouTube playlists (M, read-only).**
  As planned: yt-dlp's `:ytwatchlater`, `:ytfav` and `feed/playlists`; a
  source `(account KIND)`; `C-c y a`.  Its auth source must not treat
  empty output as expired at all: 8.4 now reports an empty feed after a
  fresh export as "no videos", but only after a re-export, which may ask
  for the keyring; an empty Watch Later is normal.  The
  `playlist_channel` fallback is off for these sources.  Checked once
  with the smoke test's setup.
- **14.2 Mute channels (S-M).**  An additive `channel_prefs` table, after
  11.1; muted channels hidden from the feed by default, `t m` shows them.
  The key is `x` ("exclude") in the feed and the channels list, not `M`,
  which 13.1 takes for audio.  Shorts have no channel, so muting cannot
  hide them.
- **14.3 Streams and Shorts tabs (S).**  `T` in a channel cycles videos,
  streams and shorts; a missing tab is an empty list.

### M13: playback (fourth; about half a session; decision 4)

- **13.1 Audio only (S).**  `M` plays a video as audio, `C-c y M`
  switches the playing one: resolve `bestaudio` and load that URL alone,
  at the current position, through the in-place reload helper of 8.6.
  The stream cache keeps it under its own format, so switching back and
  forth costs one resolve each way at most.
- **13.2 Mode line (S).**  The chapter (observing mpv's `chapter`
  property, which 9.6 made meaningful), the queue position `2/5`
  (`playlist-pos` and `playlist-count`), ♪, LIVE, and a marker when
  skipping is off, with `char-displayable-p` fallbacks.

### M15: notes (last; small)

- **15.1 Org links (S-M).**  As planned: a private link type with only a
  `:store` function, storing plain `https://www.youtube.com/watch?v=ID`
  links (`&t=N` when that video plays) and "Title — Channel".  With 9.7's
  handler on, following such a link in org plays it in yt from that
  time, so no `:follow` is needed.

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
- **Pruning the cache (was 11.3):** the sandbox's database is 388 KB
  after weeks of use; at about 100 new videos a day the real one grows
  some 10 MB a year.  Worth doing when the doctor's size (11.1) says so.
- **eldoc on rows (was 15.2):** the Title column now fits the window, so
  long titles are seldom cut.

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
- A fullscreen toggle (was 13.3): mpv's own `f` does it in its window.

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

7. Audio only on `M` (13.1), and muting on `x` (14.2)?
8. The new ceiling of 9,000 lines and 37 options?

### Taken on 2026-11-03

- Scope: M8-M10 now, then review the plan again before M11-M15.
- The mpv playlist becomes the queue (12.4).
- `/` is the only filter key; `s` stays one release as an alias (12.3).
- The browse-url handler (9.7) is enabled in the user's config.
- No release tags for now; the dotfiles keep following main (8.12).
- After the second review: audio only on `M`, muting on `x`; the ceiling
  is 9,000 lines and 37 options; M12 now, then ask before M11.

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

## Second review (2026-11-03, after M8-M10)

- **Size.**  M8-M10 added about 1,100 lines (8,280 now) and six
  options (35), reaching the ceiling.  What remains was estimated at
  about +900 lines; with 11.3, 13.3 and 15.2 deferred or cut and 11.2
  simplified, about +550, under a raised ceiling of 9,000.
- **Order.**  M12 first: it is the only milestone that removes code, it
  fixes keys that are missing today (`P` in the channels and playlists
  lists), and the keys change is the natural point for release 0.3.0.
  M11 then, before M14, whose new table needs 11.1's rollback safety.
  M14 before M13: Watch Later and muting matter more day to day than
  audio only.
- **What M8-M10 changed for the rest.**  The stream cache (9.4) keeps
  audio-only streams under their own format (13.1); chapters (9.6) make
  a chapter in the mode line possible (13.2); the link handler (9.7)
  makes stored org links play in yt without a `:follow` (15.1); the
  empty-feed fix (8.4) is not enough for an empty Watch Later (14.1).
- **A key clash.**  13.1 and 14.2 both wanted `M`; muting moves to `x`.
- **Measured.**  The sandbox cache is 388 KB and 20 thumbnails, which
  is why pruning waits.  The smoke test (10.7) passes against the real
  YouTube, so the yt-dlp-dependent items start from a working base.
- **Unchanged.**  The deferred and cut lists stand; nothing in M8-M10
  argued for bringing one of them back.


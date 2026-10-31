# yt-export-cookies: export one Chromium profile's youtube.com cookies.
#
# Copyright (C) 2026 Erik Sundin
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Packaged by flake.nix as the `yt-export-cookies' command.
#
# `yt-dlp --cookies-from-browser B --cookies FILE' writes every cookie in
# the browser, for every site, to FILE.  This script writes only cookies
# whose domain is youtube.com or one of its subdomains, to a file created
# with mode 0600 next to its destination and then renamed into place.
#
# It prints a single JSON object on stdout and never prints cookie values.
# Exit status: 0 when usable YouTube login cookies were found, 2 when
# extraction ran but found none (or could not decrypt some), 1 on error.

import argparse
import contextlib
import json
import os
import re
import sys
import tempfile

from yt_dlp.cookies import YoutubeDLCookieJar, extract_cookies_from_browser

KEYRINGS = ("GNOMEKEYRING", "BASICTEXT")
LOGIN_COOKIES = {"LOGIN_INFO"}
SAPISID_COOKIES = {"SAPISID", "__Secure-3PAPISID"}
FAILED_RE = re.compile(r"\((\d+) could not be decrypted\)")
# Chromium stores expiry as microseconds since 1601-01-01, and yt-dlp
# passes that through unchanged; anything this large is not Unix seconds.
CHROMIUM_TIME_MIN = 10 ** 11
CHROMIUM_EPOCH_OFFSET = 11644473600


class CapturingLogger:
    """A yt-dlp cookie logger that records messages instead of printing."""

    def __init__(self):
        self.messages = []

    def debug(self, message, **kwargs):
        pass

    def info(self, message, **kwargs):
        self.messages.append(("info", message))

    def warning(self, message, **kwargs):
        self.messages.append(("warning", message))

    def error(self, message, **kwargs):
        self.messages.append(("error", message))

    def progress_bar(self):
        return None


def wanted(domain, base):
    """Return True if cookie DOMAIN is BASE or a subdomain of it."""
    domain = domain.lower()
    return domain in (base, "." + base) or domain.endswith("." + base)


def extract(browser, profile, keyring, base):
    """Extract cookies with KEYRING; return (summary dict, kept cookies)."""
    logger = CapturingLogger()
    summary = {"keyring": keyring, "count": 0, "total": 0,
               "decrypt_failures": 0, "has_login_info": False,
               "has_sapisid": False, "warnings": [], "error": None}
    try:
        jar = extract_cookies_from_browser(browser, profile, logger,
                                           keyring=keyring)
    except Exception as e:  # yt-dlp raises plain exceptions here
        summary["error"] = str(e)
        return summary, []
    for level, message in logger.messages:
        match = FAILED_RE.search(message)
        if match:
            summary["decrypt_failures"] += int(match.group(1))
        if level in ("warning", "error"):
            summary["warnings"].append(message)
    kept = [c for c in jar if wanted(c.domain, base)]
    for cookie in kept:
        if cookie.expires and cookie.expires > CHROMIUM_TIME_MIN:
            cookie.expires = (cookie.expires // 1_000_000
                              - CHROMIUM_EPOCH_OFFSET)
    names = {c.name for c in kept}
    summary.update(count=len(kept), total=len(jar),
                   has_login_info=bool(names & LOGIN_COOKIES),
                   has_sapisid=bool(names & SAPISID_COOKIES))
    return summary, kept


def usable(summary):
    """Return True if SUMMARY describes a complete, decrypted login."""
    return (summary["error"] is None
            and summary["decrypt_failures"] == 0
            and summary["has_login_info"]
            and summary["has_sapisid"])


def write_netscape(cookies, dest):
    """Write COOKIES to DEST atomically, as a mode 0600 Netscape file."""
    dest = os.path.abspath(dest)
    directory = os.path.dirname(dest)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    # mkstemp creates the file with O_EXCL and mode 0600.
    fd, tmp = tempfile.mkstemp(prefix=".cookies-", dir=directory)
    try:
        jar = YoutubeDLCookieJar()
        for cookie in cookies:
            jar.set_cookie(cookie)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            jar.save(f)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, dest)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise


def main(argv):
    parser = argparse.ArgumentParser(
        prog="yt-export-cookies",
        description="Export a Chromium profile's youtube.com cookies.")
    parser.add_argument("--profile", required=True,
                        help="profile directory name (e.g. 'Profile 1') "
                             "or path")
    parser.add_argument("--browser", default="chromium")
    parser.add_argument("--keyring", choices=KEYRINGS,
                        help="keyring to use (default: try each in turn)")
    parser.add_argument("--domain", default="youtube.com")
    parser.add_argument("--output",
                        help="cookie file to write; omit to only check")
    args = parser.parse_args(argv)

    summary = None
    for keyring in [args.keyring] if args.keyring else KEYRINGS:
        summary, kept = extract(args.browser, args.profile, keyring,
                                args.domain)
        if usable(summary):
            break
    ok = usable(summary)
    summary["ok"] = ok
    summary["profile"] = args.profile
    summary["written"] = None
    if ok and args.output:
        write_netscape(kept, args.output)
        summary["written"] = os.path.abspath(args.output)
    json.dump(summary, sys.stdout)
    sys.stdout.write("\n")
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

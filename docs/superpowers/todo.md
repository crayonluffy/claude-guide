# To do

Open items, newest first. Move an item to its release notes when it ships.

## Windows Chrome: proxy time zone (added 2026-11-08)

Windows Chrome ignores `TZ` (ICU reads the Windows zone), so `CHROME_TZ` only
works on macOS and Linux. Switching the Windows time zone was ruled out (it
changes the whole PC).

- [ ] Support [fingerprint-chromium](https://github.com/adryfish/fingerprint-chromium)
  (Ungoogled Chromium based, BSD-3) as `CHROME_EXE` / `CHROME_BIN`: when that
  browser is detected, `chrome-proxy` passes `--timezone=<zone from _chrome_tz>`
  (engine level: pages, iframes and workers agree; no JS hooks to detect).
  Bash and PowerShell, with tests.
- [ ] Optional: a stable `--fingerprint=<seed>` per node, so each node keeps one
  identity; `--lang` / `--accept-lang` to match the region.
- [ ] Docs: install steps, trade-offs (single-maintainer builds, manual updates,
  no Google sync / Web Store by default, spoofing can look unusual).
- [ ] Lighter alternative to mention in `chrome-proxy -Check` on Windows:
  [Spoof Timezone](https://github.com/joue-quroi/spoof-timezone) extension in the
  proxied profile only, with "update timezone from IP" on startup (JS level;
  iframes may leak). Not Vytal: debugger bar, misses the New Tab page.

## Mac verification

- [ ] Install 2.13.x on the Mac with a rollback copy; `proxy-restart` once; check
  `chrome-proxy --check` (WebRTC, DNS, time zone via `open --env`), LAN access,
  and that brief drops no longer pop up desktop alerts.
- [ ] Shared mode with the second account (Ming).

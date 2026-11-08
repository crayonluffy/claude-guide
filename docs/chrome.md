# Browse through the proxy (Chrome)

With the profile installed, type **`chrome-proxy`**. It opens a **separate** Chrome through the **SOCKS5** proxy on `127.0.0.1:1080`. Your normal browser does not change. `chrome-proxy` starts the tunnel if necessary. It uses a separate `--user-data-dir` (separate logins, cookies and history). It sends the DNS lookups through the tunnel (no DNS leaks). In WSL, it starts **Windows** Chrome.

## Leak protection

`chrome-proxy` also guards against the usual browser leaks:

- **WebRTC** never sends UDP directly, so sites cannot see your real public IP or your local addresses. Video calls still work where the service can relay over TCP.
- **QUIC / HTTP/3** is off, so no UDP traffic goes around the proxy.
- **Your local network stays reachable.** Hosts in `NO_PROXY` (private ranges, `*.local`, any `*.mycorp.example` you add) go direct, and their names resolve on your network. Set `CHROME_BYPASS` to `off` to send them through the proxy too. A short name without a dot (`http://nas/`) cannot resolve; use its IP or full name.
- **Time zone** (macOS, Linux): Chrome uses the time zone of the proxy's exit IP, so the clock matches the IP. `CHROME_TZ` sets a fixed zone (`Asia/Tokyo`) or `off`. Windows Chrome follows the Windows time zone.
- **`chrome-proxy --check`** opens leak tests (IP, WebRTC, DNS, time zone) and prints what a pass looks like.

A Chrome window that was already open for that node keeps the flags it started with. Quit it, then run `chrome-proxy` again.

## Several regions and accounts

- **More regions at the same time:** `chrome-proxy jp`, `chrome-proxy sg`, … each open a Chrome through that node, on its own tunnel and data folder.
- **More accounts on the same node:** `chrome-proxy jp --profile work`. Refer to **[Nodes](proxy-nodes.md)**.

## Without the profile

Use these commands. The **tunnel must be up** first (`proxy-up`, or the manual step 1 `ssh` command, which gives the `-D 1080` SOCKS forward):

**🪟 Windows (PowerShell)**

```powershell
& "C:\Program Files\Google\Chrome\Application\chrome.exe" `
    --proxy-server="socks5://127.0.0.1:1080" `
    --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1 , EXCLUDE *.local" `
    --proxy-bypass-list="127.0.0.1;10.0.0.0/8;172.16.0.0/12;192.168.0.0/16;*.local" `
    --force-webrtc-ip-handling-policy=disable_non_proxied_udp --disable-quic `
    --user-data-dir="C:\ChromeVPNProfile" --no-first-run
```

**🍎 macOS**

```bash
open -n --env TZ=Asia/Tokyo -a "Google Chrome" --args \
    --proxy-server="socks5://127.0.0.1:1080" \
    --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1 , EXCLUDE *.local" \
    --proxy-bypass-list="127.0.0.1;10.0.0.0/8;172.16.0.0/12;192.168.0.0/16;*.local" \
    --force-webrtc-ip-handling-policy=disable_non_proxied_udp --disable-quic \
    --user-data-dir="$HOME/.chrome-proxy-profile" --no-first-run
```

**🐧 Linux** (if you do not have `google-chrome`, use `chromium`)

```bash
TZ=Asia/Tokyo google-chrome \
    --proxy-server="socks5://127.0.0.1:1080" \
    --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1 , EXCLUDE *.local" \
    --proxy-bypass-list="127.0.0.1;10.0.0.0/8;172.16.0.0/12;192.168.0.0/16;*.local" \
    --force-webrtc-ip-handling-policy=disable_non_proxied_udp --disable-quic \
    --user-data-dir="$HOME/.config/google-chrome-vpn" --no-first-run &
```

**🐧 WSL:** use the **Windows PowerShell** command above. WSL2 forwards `127.0.0.1:1080` to Windows automatically. (Or use `chrome-proxy`. It finds Windows Chrome for you.)

What the flags do:

- `--proxy-server` sends all traffic through the SOCKS5 forward.
- `--host-resolver-rules` also sends the **DNS** lookups through the tunnel (no DNS leaks). Each `EXCLUDE` lets a local name resolve on your network.
- `--proxy-bypass-list` lets your local network go direct (no proxy).
- `--force-webrtc-ip-handling-policy=disable_non_proxied_udp` stops WebRTC from showing your real IP; `--disable-quic` keeps HTTP/3 (UDP) off.
- `TZ=` (macOS: `open --env TZ=`) gives Chrome the proxy region's time zone; use the zone of your VM's region.
- `--user-data-dir` keeps this Chrome a **separate profile**. Your normal browser does not change.

If you changed `SOCKS_PORT`, use that port in place of `1080`. `proxy-status` shows the port.

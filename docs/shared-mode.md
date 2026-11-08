# Two accounts on one computer (shared mode)

Two macOS accounts cannot both run a tunnel on the same ports. If one account (for example `Kimmy`) already runs the tunnel on HTTP `8080` / SOCKS `1080`, the second account (for example `Ming`) can use it:

```bash
proxy-config set PROXY_MODE shared   # in the second account only
cc                                    # uses 127.0.0.1:8080 from the first account
```

- In shared mode the profile **never starts, stops or restarts** a tunnel. It checks that the configured ports answer through HTTPS, then starts Claude or Codex. The kill switch and `NO_PROXY` checks still apply.
- `cc-stop` only clears the proxy in this terminal. `proxy-restart` and `proxy-nodes use` refuse and tell you that the owning account controls the tunnel.
- `cc --node sg` works if the owning account has the tunnel of `sg` running.
- Use shared mode only with an account you trust: Claude and Codex send their traffic through whatever program listens on these ports.
- `proxy-config set PROXY_MODE managed` returns to the normal behavior.

## When something is wrong

| Symptom | Fix |
|---|---|
| The second account's `cc` reports that ports `8080` / `1080` are in use | The other account already runs the tunnel. In the second account: `proxy-config set PROXY_MODE shared`. |
| `[Shared] Restart is managed by the proxy owner` (or stop / node change) | In shared mode this account does not control the tunnel. Do it in the account that runs it. |
| `proxy-status` shows `[SHARED] Tunnel` and `Proxy answers : NO` | The owning account's tunnel is down. Type `cc` (or `proxy-restart`) in that account. |

# Proxy recovery, notifications, and safe simulation

## Agreed intent

Improve the claude-guide launchers so an HTTP proxy failure during an existing
`cc` or `cx` session produces a visible warning and automatic recovery attempts.
Keep the user's session running. After 60 seconds without recovery, explain the
outage and keep retrying; the user decides whether to exit through the CLI's
normal controls. Never inject input, automatically exit, or kill Claude/Codex.

Include a safe demonstration mode so users can see short and prolonged outages
without stopping the real tunnel, affecting other terminals, or contacting APIs.

This phase covers the guide's PowerShell and Bash launchers, including macOS,
Linux, and WSL. It improves availability and preserves configured proxy routing;
it does not claim an OS-enforced guarantee that all application/child-process
traffic cannot bypass the proxy. Firewall isolation is a separate future feature.

## Existing behavior and gaps

- Bash already has a detached SSH watchdog, HTTP-proxy probes, reconnect backoff,
  and shared-tunnel handling. Extend these mechanisms instead of duplicating them.
- PowerShell repairs stale tunnels during startup but has no continuous equivalent.
  Its current health check primarily inspects listening processes/ports.
- Proxy verification can fail without making startup fail. PowerShell verification
  also relies on ambient proxy settings rather than an explicit proxy argument.
- Existing proxy shutdown/settings cleanup is incompatible with silent automatic
  recovery if it removes proxy settings or changes the port beneath running apps.
- Terminal sessions can share the same tunnel; independent recovery loops must
  not compete to restart it or interrupt each other's sessions.

## Proposed behavior

### Health checks and startup

Before launching `cc` or `cx`, require an actual successful proxy transport check.
A failed mandatory check returns a nonzero/false result and does not launch the
application. Existing optional external-IP verification can remain separate;
`--no-verify` must not bypass this mandatory transport check.

Probe a public HTTPS endpoint explicitly through the selected local HTTP proxy,
with proxy bypass disabled, certificate verification enabled, and finite connect
and overall timeouts. Do not use API keys, submit prompts, or send a direct-IP
comparison request. Support endpoints for both Claude and Codex; rate-limit or
application authentication responses do not themselves mean the proxy is down.

Classify results:

1. Healthy transport: CONNECT succeeds, TLS is verified, and an HTTPS response
   arrives. An API's 401/403/429/5xx response is not an SSH failure.
2. Tunnel unavailable: owned SSH exited, or the explicit proxy connection hangs,
   closes, or refuses the connection. Attempt reconnection.
3. Proxy/upstream failure: the proxy answers but rejects/fails CONNECT. Report
   the distinction; restarting SSH repeatedly cannot repair remote tinyproxy or
   an upstream policy. Continue bounded probes with backoff.
4. Local port conflict: another process owns the established session's port.
   Report it and retry without terminating that process or silently changing ports.

The monitor checks approximately every five seconds, using a three-second overall
probe timeout. A first failed check triggers notification. Require two consecutive
failures before restarting a still-running SSH process to avoid reconnect storms;
an owned SSH exit can trigger reconnection immediately. Start the outage clock
at the first failed check and reset it only after a successful transport check.

### Shared recovery owner and fixed ports

Use one recovery owner per user and tunnel identity, protected by an atomic
ownership lock. Record ownership, current PID, target, fixed HTTP/SOCKS ports,
state, timestamps, failure category, and retry count in a user-private status
location. Never use a machine-wide writable shared filename as the lock.

Extend Bash's existing watchdog. Add the equivalent PowerShell background monitor
without taking over the CLI's foreground terminal or stdin. Other launchers attach
to the owner's status rather than spawning competing reconnect loops. Validate
ownership before signalling SSH; never stop unrelated SSH or non-SSH processes.

Reconnect with the same SSH destination, credentials, and established local
ports. Backoff is bounded at 30 seconds. Startup may select a free port before a
session exists; a live session's recovery must not switch its port or node.
Keep the existing HTTP(S)_PROXY environment and Claude settings throughout an
outage. Automatic recovery never invokes proxy-off, settings cleanup, or a global
shutdown command. Missing credentials/authentication failure must be reported;
background recovery must not wait on an invisible password prompt.

Remote tinyproxy failures are identified and reported with admin troubleshooting
instructions. This change does not give clients remote sudo rights or automatically
restart server services. Recovery succeeds when the service becomes reachable.

### Notifications and user control

States are `healthy`, `recovering`, and `prolonged`:

- First failure: "Proxy connection lost. Retrying; proxy settings remain enabled."
- Recovering: rate-limited progress with elapsed outage time and next retry.
- After 60 seconds: "Proxy is still unavailable. Your session has not been
  terminated. Keep retrying, or exit normally and resume later."
- Recovery: "Proxy connection restored. Your session is still running. Retry any
  failed request if the application did not retry it automatically."

The 60-second value is configurable and is a notification threshold, never a
termination deadline. Emit the prolonged warning once per outage, and recovery
once per transition. Avoid announcing a new outage for every failed poll.

Publish persistent status/log entries. While a launched `cc`/`cx` is running,
its notification subscriber prints brief warnings to that terminal's stderr;
it never sends keystrokes, prompts for a choice through the CLI's stdin, or
claims to pause application requests. The CLI may redraw its screen, so retain
messages in the log and make the latest state available through proxy-status.
Desktop toast notifications are outside this phase.

`proxy-status` shows recovery state, outage duration, retry count, the selected
ports, and the log location. Exiting a CLI normally removes its subscriber but
does not shut down a tunnel used by other sessions. An intentional user request
to stop the tunnel must stop its recovery owner first, so it stays stopped.
Preserve existing explicit shutdown confirmation/force behavior; automatic code
must never exercise that override.

### Safe test mode

Provide these commands on PowerShell and Bash:

```
proxy-test recover --fast
proxy-test prolonged --fast
```

Both run the real state-transition/notification logic with fake probe and SSH
adapters and isolated temporary state. `recover` demonstrates failure, retries,
and recovery. `prolonged` crosses the notification threshold, shows that the
session stays alive and retries continue, and ends by simulating recovery.

`--fast` uses an accelerated demonstration clock and labels all output
`[SIMULATION]`, including the fact that 60 simulated seconds are compressed.
Without --fast, demonstrations use real elapsed time. Ctrl+C ends the demo and
cleans only its temporary state. Neither mode modifies settings, starts/stops
real SSH, touches the live watchdog, launches/exits Claude/Codex, or calls a network
endpoint. These demonstrations are notification/recovery simulations, not proof
of network isolation. Real-network interruption tests are separate manual checks
on an isolated test tunnel.

## Verification and release

Add automated PowerShell and Bash tests with fake clocks/probes/process adapters:

- A failed mandatory startup check prevents application launch, including with
  optional IP verification disabled.
- A listener with a failed end-to-end probe is not reported healthy.
- Short failure warns once, recovers, retains ports/settings, and leaves app alive.
- Prolonged failure warns after the threshold and keeps retrying indefinitely.
- API-level 401/403/429/5xx through successful TLS does not restart SSH.
- Proxy CONNECT rejection and local foreign-port conflicts are classified correctly.
- Two launchers share one recovery owner; stopping one subscriber leaves the other.
- Explicit tunnel stop prevents reconnection; stale ownership is handled safely.
- Simulation scenarios invoke no real network/process/settings mutation adapters
  and cannot affect the real watchdog, even when cancelled.
- Neither normal recovery nor simulation signals or injects input into Claude/Codex.

Perform real Windows PowerShell/OpenSSH and Bash/macOS/Linux smoke tests where
available. Linux-hosted PowerShell tests alone do not validate Windows console,
background process, or ownership behavior; report unavailable platform coverage.
Document setup, expected warnings, shared-session behavior, simulation commands,
and the limits of script-level protection. Bump the appropriate platform versions
and use the established annotated `powershell-v<version>` / `bash-v<version>` tags
when the implementation is reviewed, tested, and authorized for publication.

## Review status

The conversational behavior is approved. This written specification is awaiting
user review; no product implementation has started. After written-spec approval,
prepare the implementation plan and its execution choice before coding.

# Shared proxy clients and safe node control

The user reports Ming's cx cannot use ports 8080/1080 while Kimmy owns them.
They also request better multi-node configuration and investigation of races
when changing the default node. Keep the completed quiet-terminal work.

## Evidence and intended behavior

Kimmy's UID 501 SSH owns both listeners. Ming is UID 502; Ming's profile and
recovery state are private and cannot be read from Kimmy's account without sudo.
The existing wrapper requires a locally owned SSH pair; a valid proxy served by
another account consequently fails readiness/ownership checks. TCP clients can
share that listener; the second account must not create another listener.

Four simultaneous fresh Kimmy shells passed cc/cx version launches, but this
only establishes steady-state startup. An isolated audit reproduced a new tab
reclaiming the old default during a switch, a session registering after an
unforced-switch check, and named Chrome profiles changing region because they
borrow the movable main endpoint. Main ports themselves stay 8080/1080.

## Approach

1. `PROXY_MODE=managed|shared` (`CLAUDE_PROXY_MODE` for shell), default managed.
   Shared mode explicitly trusts the configured local HTTP/SOCKS endpoints.
   Probe HTTPS through them, keep NO_PROXY/pinning checks, and never start,
   stop, restart or subscribe as a private owner. Shared clients may select an
   explicit node whose endpoints the owner has started. The owner controls the
   server behind the shared main endpoint. No silent automatic attachment.
2. A per-account operation coordinator serializes starts, switches/restarts,
   and default application startup through session registration. Release before
   running the application. Reuse verified process identities for stale locks.
   Same-account nested calls can reuse the operation; unrelated tabs cannot.
3. Named nodes always use stable node slots, including when that node is the
   current default. Only an unqualified cc/cx/proxy-up uses main. Thus named
   Chrome JP/SG/US keeps SOCKS 1180/1181/1182 across default changes. Main remains
   on its configured HTTP/SOCKS ports. Explicit restarts that change local ports
   continue to require affected applications to relaunch.
4. Improve proxy-config edit with editable per-node HTTP/SOCKS assignments,
   saved/planned/running views, and occupied-port diagnostics. Preserve shared
   base+slot defaults when no override exists. Validate duplicates and ranges
   before saving, preserve live owners until explicit restart, and never kill
   another account's program. Materialize all catalogue/known active nodes.

## Alternatives and assumptions

Separate ports for every OS account avoid conflicts but do not meet the user's
request to share the existing service. Automatically trusting any listener
would change the meaning of managed mode, so sharing is explicit. Stable named
node slots replace borrowing main; this uses an extra SSH connection when a
named node and main target the same server, in exchange for predictable routing.
Per-node editing is the recommended assumption while the optional preference
question remains unanswered. Implement the coordinator and explicit sharing
before editor changes; do not claim version checks prove all concurrency cases.

Retain standalone Mac/Linux/PowerShell installs. No real cross-account execution
or writes to Ming's private files are possible without Ming's cooperation;
report fixture tests and actual local network checks accurately. Version 2.13.0
includes the quieter terminal policy already committed as ea11656.

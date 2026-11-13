# LockedIn design

This document explains why LockedIn is built the way it is: what each piece guards against, what it
costs, and which alternatives were rejected. The README says what LockedIn does; this says why.

## The one rule

**Nothing ends a block early.** Every other decision is checked against this rule. A feature that
adds a way out of a running block is wrong, unless the way out is deliberate and documented (there is
exactly one; see [The one way out](#the-one-way-out)).

### Who LockedIn defends against

The adversary is the user, later, at a weak moment: an administrator with a terminal and
motivation, but no plan. The goal is to make ending a block take deliberate, multi-step effort that
outlasts the impulse.

Non-goals:

- **Root, malware, or a determined attacker.** Root can unload any daemon and edit any file. LockedIn
  doesn't pretend otherwise. "Hard to undo on impulse" is reachable; "impossible" is not.
- **Parental control or managing someone else's Mac.** Any administrator can start a block, a block
  covers the whole Mac, and there are no per-user policies.

## Shape

Three programs, one source of truth:

| Program | Runs as | Job |
|---|---|---|
| `lockedind` | root, launchd `KeepAlive` | Applies the block, guards it, counts it down, persists it |
| `lockedin` | the user | CLI: start, status, add, extend, list, preview, doctor, install |
| `LockedIn.app` | the user | Menu bar countdown and start sheet |

Only the daemon touches the system. The CLI and app ask it for things over a unix socket
(`/var/run/lockedin.sock`, mode 0660, owner `root:admin`). Each request is one line of JSON on its own
connection. The daemon checks the peer's credentials (`LOCAL_PEERCRED`, including supplementary
groups, because on macOS `admin` is a supplementary group) and accepts root or members of `admin`.

**The protocol has no stop, cancel, or remove command.** The only enforcement of "no early exit"
that cannot have a bug is code that does not exist. The commands are `status`, `version`, `start`,
`add`, and `extend`. Starting a block requires the `com.tgreco.lockedin.start` authorization right
(Touch ID or password, rule `authenticate-admin`). `add` and `extend` need no prompt, because they
can only make the block stricter or longer.

Rejected:

- **SMAppService / a blessed privileged helper over XPC.** That is the Apple-blessed path, but it
  needs a signed, notarized app with a Team ID, and LockedIn is built from source and ad-hoc signed
  on purpose: the only way to trust what runs as root is to build it yourself. SelfControl uses a
  blessed helper and re-blesses it on every block start, so its install prompt comes back again and
  again.
- **A Network Extension content filter.** It could match traffic by app and resolver, but it needs
  entitlements and notarization, for the same reason as above.

## Two enforcement layers: hosts and pf

Each site is blocked twice, once by name and once by address. Either layer alone leaks.

**`/etc/hosts`** maps every blocked name to `0.0.0.0` and `::`. It is cheap, catches every
subdomain LockedIn knows about, doesn't care when addresses rotate, and blocks a name without
touching any address another service shares. It leaks when something skips the system resolver:
DNS over HTTPS in a browser, an app with its own resolver, or a hard-coded IP.

**pf**, the macOS packet filter, blocks by destination address in the kernel, whatever resolved the
name. It leaks in the other direction: addresses rotate, and CDNs put unrelated sites on the same
addresses, so a firewall rule can block things nobody asked to block.

How they combine:

- Every plain host name goes in the hosts section.
- The daemon resolves names with `dig`, which asks the nameservers directly. The system resolver
  would return LockedIn's own `0.0.0.0` once the hosts section is in place. The addresses go into a
  pf table.
- The address set is **add-only** for the whole block. Names are re-resolved every 3 minutes and new
  addresses are added, never removed, so rotation can only tighten a block. When new addresses are
  added, existing connections to them are killed (`pfctl -k`), so a tab that's already open stops
  working too.
- Raw IPs and networks (`203.0.113.0/24`) go straight into the table. Entries limited to a port get a
  per-port table and a `proto { tcp udp } ... port N` rule.
- **Google-family names are hosts-only.** `youtube.com`, `google.com` and the rest share front-end
  addresses with Gmail, Docs and Meet, so firewalling them would break unrelated work. The cost is
  the DoH leak, documented in README › Limits.
- **`~site` is hosts-only on request**, the user's escape hatch when a site's CDN addresses are
  shared with something they need.

The rule is `block return`, not `block drop`: a blocked connection fails at once instead of hanging
until a timeout, which reads as "blocked" instead of "the internet is broken".

Rejected:

- **Hosts only.** One browser setting (DoH) defeats it.
- **pf only.** It misses addresses that rotate between resolves, can't block the Google family
  safely, and does nothing about the name itself.
- **A local DNS proxy.** It would replace the hosts file with a resolver LockedIn controls (wildcards,
  no stale entries), but it is a root-owned network service on the critical path of every lookup, and
  it still would not see DNS over HTTPS. It fights VPN DNS and fails closed for the
  whole Mac if it crashes. Too much blast radius for a focus tool.

### Where the pf rules live

The rules load into the anchor `com.apple/300.lockedin`. Stock `/etc/pf.conf` already references
the wildcard `com.apple/*`, and pf evaluates its children, so **`/etc/pf.conf` is never edited**.
SelfControl edits `pf.conf`. An OS update can restore that file, and an edited copy left behind
after an uninstall is someone else's problem to debug.

Further rules:

- pf is enabled through **reference tokens** (`pfctl -E`, released with `pfctl -X <token>`), not
  `pfctl -e`/`-d`. If something else on the Mac also needs pf, LockedIn never turns pf off under it.
- Flushes are **anchor-scoped only**. LockedIn never runs `pfctl -F all` or `-F states`, which would
  drop every connection on the Mac.
- If the main ruleset loses its `com.apple/*` reference, the daemon reloads `/etc/pf.conf`. It
  waits at least 60 s after boot, because macOS loads the main ruleset late, and at most once a
  minute.

## The hosts contract

The daemon owns one marked section of `/etc/hosts`, appended at the end the first time:

```
# BEGIN LOCKEDIN BLOCK -- managed by com.tgreco.lockedin.daemon; re-applied until the block ends; do not edit
0.0.0.0	youtube.com
::	youtube.com
# END LOCKEDIN BLOCK
```

**The hosts section is owned exclusively by LockedIn, and pre-existing entries are never touched.**

What that means in practice:

- **Every write is a splice.** The file is read as lines with their own terminators. Bytes outside
  the markers are copied verbatim, including line endings, trailing whitespace and blank lines. The
  section, from its begin marker through its end marker's terminator, is replaced whole, in place.
  If there is no section yet, it is appended.
- **The section uses the file's dominant line ending.** If more lines end in CRLF than in LF, the
  section is written with CRLF, so a CRLF file stays consistent.
- **Starting a block** leaves every pre-existing line where it was. That includes lines for the same
  sites: a hand-written `0.0.0.0 facebook.com` stays, and the section adds its own copy. A
  duplicate is harmless; deleting someone's own entry is not.
- **Ending a block** removes the bytes between the markers and nothing else.
- **An unterminated section** (begin marker, no end marker) owns only the run of `0.0.0.0`/`::`
  lines right after the begin marker. The first other line, and everything after it, is kept.
- **The marker strings never change.** The daemon finds its section only by the markers, and no
  other record of it exists. Renaming them would orphan every section already written to a live
  Mac. The strings are asserted literally in the tests.
- **The old SelfControl section** (`# BEGIN SELFCONTROL BLOCK`) is removed by `lockedin install`,
  once, as a migration: SelfControl is uninstalled in the same step and its list imported first.
  The daemon never touches it. `lockedin doctor` reports one that is still there.

Trade-off accepted: if someone deletes only the two marker lines during a block, the lines that were
between them are no longer LockedIn's. The 15 s check sees the section missing and writes a fresh
one. The orphaned lines stay after the block ends, and those sites stay blocked until the person
removes them. LockedIn won't guess which unmarked lines it once wrote. An earlier version did guess,
and it deleted users' own entries.

One byte can be added outside the section: if the file does not end with a newline, the section
needs one in front of it to start on its own line, and that newline stays after the block ends.
The stock macOS `/etc/hosts` ends with a newline, so in practice this does not happen.

How writes happen: the new text goes to a temporary file next to `/etc/hosts`, gets the original's
mode and owner, and is `rename(2)`d into place. Nobody ever reads a half-written hosts file. After a
change the daemon flushes the DNS cache (`dscacheutil -flushcache`, `killall -HUP mDNSResponder`).

## Time: monotonic for the countdown, wall clock for display

The countdown runs on `CLOCK_MONOTONIC`. It cannot be set by the user, and on macOS it keeps
counting while the Mac sleeps, so closing the lid doesn't pause a block. The wall clock is used only
to *show* times (started at, expected end), never to decide when a block ends. **Changing the date
or time zone changes nothing.**

Persistence: every 10 s the daemon saves the remaining seconds, the monotonic timestamp, and the
kernel's boot session UUID. On start-up:

- **Same boot** (daemon killed and restarted by launchd): resume from the saved remaining time minus
  the time since it was saved, measured on the monotonic clock. Downtime counts toward the block.
- **Different boot**: the monotonic clock reset to zero at boot, so the time the Mac was off can't be
  measured from it. Resume from the saved remaining time. **A reboot never shortens a block.** It
  pauses while the Mac is off, and the last save can add up to 10 s.

Rejected:

- **A wall-clock end time.** Changing the date ends the block, which is the bug this design exists
  to prevent.
- **Wall clock checked against network time.** It adds a network dependency to the countdown, and
  going offline would decide the outcome.
- **`mach_absolute_time` / `CLOCK_UPTIME_RAW`.** They stop while the Mac sleeps, so a block would
  quietly stretch by every hour the lid was closed.

When schedules land (#2), the wall clock will decide only when a block *starts*. Once started, the
block counts down on the monotonic clock like any other. Editing a schedule never shortens a block
that is already running.

## Drift correction

Anything outside the daemon can change `/etc/hosts` and pf at any time. The daemon doesn't trust
its last write. It re-checks:

| What | How often | Why that often |
|---|---|---|
| Countdown | every 1 s | Expiry should land within a second of the real end |
| Save state | every 10 s | Bounds what a crash or reboot can add |
| Hosts and pf integrity | every 15 s | Each check forks several `pfctl` processes. 15 s is short enough that disabling pf to sneak a page load is not worth it |
| `/etc/hosts` changes | immediately (vnode watcher, 300 ms debounce, 600 ms when the file was replaced) | Editing the file is the most obvious tamper, so it gets the fastest answer |
| Re-resolve names | every 3 min | Catch rotated addresses without hammering DNS |

The integrity check re-applies whatever drifted: the hosts section, pf enabled, the main ruleset's
anchor reference, the anchor's rules, and every expected address present in its table. **The 15 s
loop is the backstop for everything else.** The file watcher is an accelerator, not a substitute. pf
has no change notifications, so polling is the only option there.

## State

`/Library/Application Support/LockedIn/state.json` is owned by root, mode 0644. It is world-readable,
so the app can show a countdown even when the daemon isn't answering; only root can write it.

- Writes are atomic (temporary file + `rename`). The previous good copy is kept as `state.json.bak`.
- An unreadable file is moved aside to `state.json.corrupt-<time>`, and the daemon falls back to the
  backup.
- If both files are unreadable, the daemon stays idle and **leaves hosts and pf as they are** rather
  than guess. (A known gap: the next restart sees no state at all and cleans up. It is logged for
  a fix.)
- The document has a `schema` number. **Any new field must decode from an older file**, as an
  optional or with a default. `make install` during a block upgrades the daemon, and the new daemon
  must resume the old block. If it can't read the old state, the block is lost, which is an early
  exit.

## The CLI may be newer than the daemon

The CLI and app are built from the same source as the daemon, but nothing makes them run as a
matched set. Someone can run `.build/release/lockedin` without installing it, or update the app
while an older daemon keeps running a long block. **Never assume parity.**

Rules for protocol changes:

1. **Within a protocol version, changes are additive only.** New request and response fields are
   optional. An older daemon ignores request fields it doesn't know (a test pins this), and an older
   CLI ignores response fields it doesn't know.
2. **A field that changes what a request means must not rely on being ignored.** Allowlist mode is
   the example: an older daemon would drop `mode`, start an ordinary block, and block exactly the
   sites the user wanted to keep. For such a field, the CLI first asks the daemon for `version` and
   refuses if it is too old, or the request moves to a new protocol version.
3. **`protocolVersion` changes only for incompatible changes.** The daemon rejects a version it
   doesn't support with a clear error, and the CLI shows it. `lockedin doctor` flags any CLI/daemon
   version mismatch and says to reinstall.

Today the protocol is version 1. The daemon accepts exactly version 1, and no command needs
negotiation yet. Rule 2 becomes live with allowlist mode (#1).

## The one way out

These are the ways out a user might try, and what each one does:

| Attempt | Result |
|---|---|
| Quit the app, delete the app | The app is only a client. The block continues. |
| `kill` the daemon | launchd restarts it within seconds. It resumes; downtime counts. |
| Reboot | The daemon starts at boot and resumes. The block pauses while the Mac is off. |
| Change the clock | No effect. The countdown is monotonic. |
| Edit `/etc/hosts` | Re-applied immediately by the watcher, or within 15 s at worst. |
| `pfctl -d`, flush the anchor | Re-applied within 15 s. |
| `lockedin uninstall` | Refused while a block is running. It checks the live daemon *and* the saved state, so stopping the daemon first doesn't help. |
| Disable LockedIn in System Settings › Login Items, or `launchctl bootout` as admin | **Works.** The countdown pauses and re-application stops. The hosts entries stay. |

The last row is deliberate. macOS lets an administrator stop a launch daemon. Fighting that would
mean persistence tricks this project won't ship. It takes an administrator, System Settings, and
intent: enough friction for the threat model above.

## Testing

- `LockedInCore` is pure logic: parsing, expansion, plan compilation, hosts and pf rendering,
  countdown arithmetic, protocol coding. Swift Testing covers it, including edge cases that pin
  documented behaviour.
- `lockedindTests` runs a real `BlockController` under a **relocated root**
  (`RuntimePaths(root:)`, the same mechanism as `LOCKEDIN_TEST_ROOT`). Every system path moves into
  a temporary directory and `pfctl` is simulated. This is where daemon behaviour such as hosts
  ownership is tested without root.
- `scripts/smoke-test.sh` is the end-to-end check on a real Mac, as root. It runs a real block, tampers
  with hosts and pf, kills the daemon, and checks that everything is restored and then removed at
  expiry.
- CI builds and tests on macOS 15 (Xcode 26 selected) and macOS 26, and gates on
  `swift format lint --strict`.

# LockedIn

Block distracting websites on your Mac for a set time. Once a block starts, **nothing ends it
early**: not quitting the app, not restarting, not deleting the app, not changing the clock.
You wait it out.

LockedIn is a from-scratch replacement for [SelfControl](https://github.com/SelfControlApp/selfcontrol),
which stopped working reliably on recent macOS releases. It is a menu bar app, a command line
tool, and a small root daemon, written in Swift, built from source with one command.

```
$ lockedin start 2h youtube.com reddit.com
Block started for 2h, ends at 4:12 PM.
  sites: youtube.com reddit.com
  14 names go in /etc/hosts; firewall addresses fill in over the next few seconds.
There is no stop button.
```

## What it does

- **Blocks by name and by address.** Each site goes into `/etc/hosts` (pointed at `0.0.0.0`) and
  its IP addresses go into a `pf` firewall table, so browsers that bypass the hosts file still
  hit a wall. Addresses are re-resolved every few minutes and only ever added.
- **Survives everything.** A launchd daemon (`lockedind`) runs as root, restarts if killed,
  re-applies the block within seconds if `/etc/hosts` or the firewall is edited, and resumes
  after a reboot. The countdown runs on the monotonic clock, so changing the system time does
  nothing.
- **Asks before it starts.** Starting a block takes Touch ID or your password, once. After
  that there is no cancel, stop, or uninstall path until the timer ends.
- **Adds the obvious variants.** `youtube.com` also blocks `www.youtube.com`, `m.youtube.com`,
  `youtu.be`, and friends. `twitter.com` and `x.com` cover each other. (Turn this off with
  `--no-expand` or in Settings.)
- **Imports your old SelfControl list** the first time it runs, and removes SelfControl's
  leftover helper, launchd job, and firewall anchor when you install.

## Install

Requirements: an administrator account, and Xcode 26 or newer (or its Command Line Tools) for
Swift 6.2. Xcode 26 itself needs macOS 15.6 or newer, and since you build on the Mac you install
on, that is the real floor. The built binaries target macOS 14.

```bash
git clone https://github.com/tgrecojs/lockedin.git
cd lockedin
make install
```

`make install` builds everything as you, then asks for your password once to install the
daemon (`/Library/PrivilegedHelperTools/com.tgreco.lockedin.daemon`), its launchd job, the
`lockedin` command in `/usr/local/bin`, and `LockedIn.app` in `/Applications`.

macOS lists the daemon under **System Settings › General › Login Items & Extensions › Allow
in the Background**. Leave it allowed.

There are no downloadable binaries on purpose: the app is not notarized, and building it
yourself is the only way to be sure what runs as root on your Mac.

## Use

**Menu bar app.** Open LockedIn from Applications. A lock icon appears in the menu bar. Pick a
length, edit your list, press Start. While a block runs the icon shows the countdown; you can
add sites or extend the time, nothing else.

**Command line.**

```bash
lockedin start 25m                       # block your saved list for 25 minutes
lockedin start 2h youtube.com x.com      # block these sites (and your list is not used)
lockedin status                          # how long is left, what is blocked
lockedin status --watch                  # live countdown
lockedin add news.ycombinator.com        # add to the running block (never remove)
lockedin extend 30m                      # add time to the running block
lockedin list                            # show the saved blocklist
lockedin list add reddit.com             # save a site for next time
lockedin preview reddit.com example.com:8080   # see what would be blocked, without blocking
lockedin doctor                          # check that everything is installed and healthy
```

Durations: `25m`, `2h`, `1h30m`, `1d`, or a plain number of minutes.

Sites: `youtube.com`, `example.com:8080` (one port only), `203.0.113.0/24` (a network),
`~reddit.com` (hosts file only, see below). Pasted URLs work; the path is dropped.

The saved blocklist is a plain text file, one site per line: `~/.config/lockedin/blocklist.txt`.

## How it works

1. `lockedin start` (or the app) asks macOS for the `com.tgreco.lockedin.start` authorization
   right. That is the Touch ID / password prompt. The daemon verifies it before doing anything.
2. The daemon writes a marked section at the end of `/etc/hosts`:
   ```
   # BEGIN LOCKEDIN BLOCK -- managed by com.tgreco.lockedin.daemon; ...
   0.0.0.0	youtube.com
   ::	youtube.com
   ...
   # END LOCKEDIN BLOCK
   ```
   and flushes the DNS cache.
3. It resolves each site with `dig` (which ignores `/etc/hosts`) and loads the addresses into a
   `pf` table inside the anchor `com.apple/300.lockedin`. That anchor sits under Apple's own
   `com.apple/*` wildcard, so `/etc/pf.conf` is never edited. The rule is
   `block return out quick from any to <lockedin_blocked>`: connections fail at once instead of
   hanging. Existing connections to those addresses are dropped.
4. Every second it counts down using `CLOCK_MONOTONIC`. Every 10 seconds it saves the remaining
   time to `/Library/Application Support/LockedIn/state.json` (root-owned). Every 15 seconds it
   checks `/etc/hosts` and `pfctl` and re-applies anything that drifted. Every 3 minutes it
   re-resolves the sites and adds any new addresses.
5. When the countdown hits zero it removes the hosts section, flushes its anchor, releases its
   pf reference, and flushes DNS. Nothing else on the system is touched.

If the daemon is killed, launchd restarts it and it resumes from the saved remaining time. On
the same boot its own downtime is subtracted; after a reboot it resumes from the saved value, so
a restart can only make a block a few seconds longer, never shorter.

## Limits

- **Google sites are blocked by name only.** `youtube.com`, `google.com`, and the rest share
  front-end addresses with Gmail, Docs, and Meet, so LockedIn never adds their IPs to the
  firewall. That means a browser configured to use DNS over HTTPS can still reach them. In
  Firefox, set *DNS over HTTPS* to *Off* (Settings › Privacy & Security) so the hosts file
  applies. Safari and Chromium browsers honour the hosts file by default.
- **Shared hosting cuts both ways.** Firewalling a site's addresses can block unrelated sites
  on the same CDN addresses for the length of the block. Prefix a site with `~` to block it by
  name only if that happens.
- **VPNs and proxies** may carry traffic the firewall never sees.
- **No wildcards.** `*.example.com` is not supported; list the subdomains you mean.
- **No allowlist mode, schedules, or per-app blocking** yet. See [Roadmap](#roadmap).
- **Disabling the daemon in Login Items** (an administrator can) pauses the countdown and stops
  re-application, though the hosts entries stay. That is the one way out, and it is deliberate
  that it takes an administrator and a trip to System Settings.

## Roadmap

In order. Each item has an issue with its scope and the rules it must not break; the main one is
that nothing ends a block early.

1. **Allowlist mode** ([#1](https://github.com/tgrecojs/lockedin/issues/1)). Block everything
   except the sites you list. Firewall only, since `/etc/hosts` cannot express "everything except".
2. **Schedules** ([#2](https://github.com/tgrecojs/lockedin/issues/2)). Start blocks on chosen
   days and times. A block that has started still runs to its end if the schedule changes.
3. **Per-app blocking** ([#3](https://github.com/tgrecojs/lockedin/issues/3)). Block apps, not
   just sites. The mechanism is still open; each option has a real cost.
4. **Reflection layer** ([#4](https://github.com/tgrecojs/lockedin/issues/4)). Mindfulness around
   a block: an intention and optional breathwork before, a note on how it went after. It needs a
   backend, which LockedIn does not have, so it is furthest out. It will never be able to end or
   pause a block.

## Can I end a block early?

No. There is no command, button, or setting for it, and `lockedin uninstall` refuses to run
while a block is active. If you have root and read the source you can of course take the
machine apart; the point is that it takes real effort.

## Uninstall

```bash
sudo lockedin uninstall        # or: make uninstall
```

Removes the daemon, its launchd job, the pf anchor, the CLI, and the app. Your blocklist in
`~/.config/lockedin` stays. Refused while a block is running.

## Development

```bash
swift build          # debug build of everything
swift test           # unit tests for parsing, expansion, hosts/pf rendering, countdown, protocol
make app             # build/LockedIn.app (ad-hoc signed)
sudo make smoke      # end-to-end test on this Mac: starts a real 2-minute block
```

The daemon can run unprivileged for development: set `LOCKEDIN_TEST_ROOT` to a scratch
directory (every system path is relocated under it and `pfctl` calls are simulated) and
`LOCKEDIN_SOCKET` to a short socket path, then run `.build/debug/lockedind`. The CLI and app
use the same variables.

Layout: `Sources/LockedInCore` (pure logic, tested), `Sources/LockedInClient` (socket client,
authorization, blocklist file), `Sources/lockedind` (the daemon), `Sources/lockedin` (the CLI
and installer), `Sources/LockedInApp` (SwiftUI menu bar app). Every name and path lives in
`Sources/LockedInCore/Identifiers.swift`.

## Credits

Inspired by SelfControl by Charlie Stigler and Steve Lambert, which did this job for years.
LockedIn shares no code with it.

## License

GPL-3.0. See [LICENSE](LICENSE).

# LuCI Subscription Toolkit — v0.3.0 development

An independent LuCI extension for subscription management and VLESS measurements.
Checks installed Podkop/sing-box capabilities; unknown versions do not block operations. This is not an official Podkop product and is
not affiliated with its maintainers. [Русский](README.ru.md).

v0.2.0: [policy, deadlines and history](docs/V0.2.0.md). [Changelog](CHANGELOG.md).

## Features

- Preferred server and stable-ID reserve priorities; recovery refreshes the subscription first.
- Deadline-bound minute monitoring, optional latency switching and guarded failback.
- Bounded hourly HTTPS sample/switch history with 24h, 7d and 30d SVG charts.
- Additional native Podkop `Exclusion` sections.
- Optional stable-ID-bound `antigravity` Proxy/Mixed Proxy, refreshed on apply and restored on rollback.
- Serialized scheduled fetch/due with bounded priority waits; clock-jump-safe minute health.

- Fetch a validated subscription candidate without switching MAIN; apply separately.
- Stable node IDs, selected-node persistence, candidate validation and rollback.
- Preserve user domains and independent settings during apply and rollback.
- Finite cron jobs for fetch, health and deferred apply. No permanent controller.
  Automation starts disabled; normal apply defaults to manual confirmation.
- Batch HTTPS latency, bounded throughput and strict Telegram Web checks using
  one temporary sing-box process. Up to eight light probes run concurrently;
  throughput probes run sequentially without fixed pauses between servers.
  Measurements do not switch MAIN. Full 4 MiB downloads below 0.5 seconds remain
  numeric and are marked as short samples.
- Private subscription URL and state. Public RPC excludes URLs, server addresses,
  UUIDs and keys. The masked URL field writes outside the shared LuCI UCI queue.

## Compatibility

Unknown OpenWrt, Podkop and sing-box versions produce a diagnostic warning, not
a global prohibition. Package dependencies do not pin Podkop/sing-box versions.
LuCI reports prerequisites separately for fetch, monitoring, Selector, switching,
apply, rollback, recovery and measurements. These are preliminary checks, not
certification of an arbitrary device or build.

HTTPS downloads are parsed and saved privately as `/etc/podkop-tools/download.json`
even if native staging is unavailable. Staging failures have their own diagnostic;
a previous pending candidate is removed rather than reused as fresh data.
Apply/rollback retain native staging, `sing-box check`, route/ownership/conflict
validation and checksummed backups. Only implementation/version allowlisting is
removed. Switching to an accepted recovery server does not need the generator;
changing its endpoint uses the full apply transaction.

The internal generator contract was compared for Podkop 0.7.14 and 0.7.22. See
[the operation matrix and test limits](docs/COMPATIBILITY.md). Docker userspace
checks do not certify OpenWrt 25.12.2 on ARM hardware. The addon does not replace
sing-box, upgrade dependencies or firmware. Particular profiles may need optional
build capabilities such as uTLS/Reality.

The subscription format is a JSON array of Xray configurations, using `remarks`
and compatible VLESS outbounds: TCP/gRPC with TLS/Reality (synthetic tests also
use security=none). URI/base64 lists, XHTTP and arbitrary provider formats are not
supported. Provider inbounds, DNS and routing are never imported.

## Build from public sources

Requirements: Linux x86_64, Python ≥3.12, Node.js ≥20 and fakeroot; Python <3.14
also needs `zstd`. Downloads are hash-pinned in `tools/sources.lock.json`.
APK building does not require Docker, a router, a private subscription or FlowPilot.

```sh
python3 tools/prepare.py
python3 tools/build-podkop-tools.py \
  --apk .build/openwrt-imagebuilder-25.12.5-x86-64.Linux-x86_64/staging_dir/host/bin/apk \
  --output dist
python3 tests/reproducibility.py
```

Outputs: `dist/luci-app-subscription-toolkit-0.3.0-r0.apk` and `SHA256SUMS`.
The builder normalizes timestamps/permissions and verifies root ownership. The
APK is unsigned. For an OpenWrt SDK build, place this directory in
`package/luci-app-subscription-toolkit`, then run
`make package/luci-app-subscription-toolkit/compile V=s`.

## Install

Check compatibility and make your own configuration backup first. Prepare the
dependencies listed in `Makefile`; no mandatory Podkop/sing-box upgrade is required.
The old `luci-app-podkop-tools` package and this package cannot coexist because
they share internal files. Migration of an existing home installation is outside
this publication's scope.

Transfer your **locally built and verified** APK to the router, then run there:

```sh
apk add --allow-untrusted /tmp/luci-app-subscription-toolkit-0.3.0-r0.apk
```

`--allow-untrusted` is required for this unsigned local APK. Installation does
not fetch a subscription, reload MAIN or enable periodic checks. Open
**Services → Subscription Toolkit: подписка и скорость**. The existing UI remains
in Russian; the English documentation does not imply an English UI translation.

## Configure a subscription

The Servers page refreshes public status without importing or applying changes.
The check panel and per-row Test button run the checked diagnostics; More opens
individual tests. A single backend batch checks all accepted servers or the active
server. Stop cancels further dispatch and waits for active bounded probes to clean
up. Speed checks require consent to the total configured traffic cap. Different
servers run without a fixed pause; repeated speed probes of the same stable ID
within 60 seconds are skipped with an explicit cooldown result. A busy backend
rejects the batch rather than silently losing it. Latency, speed and Telegram Web
availability remain independent; stale measurements are marked. Technical data
is under Details. Pending candidates are excluded from this panel.

1. Enter an HTTPS subscription URL in settings. An empty replacement field keeps
   the existing URL. Redirects and URL userinfo are rejected; TLS is verified.
2. Fetch the subscription. This validates a candidate without applying MAIN.
3. Review changes and the selected node; confirm the exact candidate version.
   Apply always fetches and validates the source again.
4. Enable automation explicitly. Defaults: fetch every 6 hours, health every
   15 minutes, candidate TTL 12 hours, window deferral 6 hours and maximum change
   series delay 24 hours.

An apply requiring reload can interrupt connections. Removing the selected node
requires a verified fallback. If all candidates fail, MAIN remains unchanged;
there is no automatic DIRECT fallback for PROXY. Recovery requires two separated
failed health probes, with at least 30 minutes between recovery attempts.

The URL lives in `/etc/config/podkop_tools_subscription` (0600); settings in
`/etc/config/podkop_tools`; accepted state, pending candidates and rollback data
in `/etc/podkop-tools` (0700/0600). These files and backups contain secrets and
must not be attached to issues.

## Updates and diagnosis

The addon does not run `apk update/upgrade`, pin official packages or patch their
files. After updating Podkop/sing-box, recheck the operations you use; unknown
versions are reported as warnings. Update the addon with a verified APK using the same `apk add --allow-untrusted /tmp/<APK>`
command after checking compatibility. Reinstalling this package preserves private state.

Run on the router:

```sh
/usr/libexec/podkop-tools/task status
/usr/libexec/podkop-tools/generate --check
sing-box version
logread -e podkop-tools
```

Report versions, the public error code and a sanitized status. Node labels may
still identify your provider; review them before posting. For `state_conflict`
or `recovery_conflict`, do not delete state or perform a blind rollback.
Concurrent external MAIN edits during apply are unsupported. Editors bypassing
UCI flock are not serialized by its native lock.

## Measurement limits

Throughput defaults to 4 MiB/6 seconds, capped at 16 MiB/15 seconds, one node per
job and at most once a minute. It uses actual received bytes, excluding TTFB;
minimum sample: 256 KiB and 0.5 seconds. Testing consumes bandwidth.
HTTP204 proves only control-endpoint reachability. Telegram Web checks do not
prove MTProto, messaging or calls; UDP/Discord Voice are not tested.
Public DNS/health/speed/service defaults are listed in the configuration; their
availability through your provider is not guaranteed. Offline lab scenarios use
controlled synthetic endpoints.

## Tests

```sh
python3 tools/prepare.py --lab
npm ci --ignore-scripts
python3 tests/run.py all
```

Docker, host OpenSSL and enough resources for a second sing-box are required.
The lab uses a dedicated internal Docker network, container-only NET_ADMIN/NET_RAW
and controlled HTTPS/DNS/VLESS fixtures inside the namespace. Python and the
browser use public digest-pinned images. No host ports are exposed, and workstation
VPN/proxy/firewall settings are not changed. Existing test resources are never
adopted; owned containers and the network are removed in `finally`. The Python
driver uses the Docker socket to manage lab resources; use a trusted checkout.
Individual suites: `unit`, `integration`,
`recovery`, `rotation`, `ownership`, `readiness`, `browser`.
Docker uses the host kernel: this verifies userspace, not hardware forwarding,
Wi-Fi or router reboot. Legacy-schema migration uses synthetic state and does
not certify upgrades from historical r2/r3 binaries.

## Remove

Run `apk del luci-app-subscription-toolkit` on the router. Owned cron/boot jobs
are disabled; Podkop and MAIN remain intact. Settings and `/etc/podkop-tools`
are deliberately preserved. After uninstalling, if no longer needed, separately
remove `/etc/config/podkop_tools`, `/etc/config/podkop_tools_subscription` and
`/etc/podkop-tools`. This irreversibly deletes the subscription, state and recovery
snapshots. Do not clear these files during an unfinished transaction.

## Publication audit

Audits exported files and all Git objects without printing matched values.
Exceptions are limited to an exact file, category and reviewed value SHA256.

```sh
python3 tools/prepare.py --audit
python3 tests/test_audit.py
python3 -B tools/prepublish.py
```

## License

Original work: [GPL-2.0-only](LICENSE). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for provenance and dependency notices.
Podkop is mentioned descriptively for compatibility; no trademark rights are granted.

The required publication gate is `python3 -B tools/prepublish.py`; see
[security policy](docs/SECURITY.md). Install the local push guard in each clone
with `git config core.hooksPath .githooks`. The guard also requires candidate
bytes to equal HEAD; committing remains a separately authorized action.

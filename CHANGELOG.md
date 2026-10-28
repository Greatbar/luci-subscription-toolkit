# Changelog

## 0.3.0 — development

- Replace implementation hash and exact-version allowlisting with independent
  operation prerequisites; unknown versions are diagnostic warnings.
- Preserve successful private downloads when Selector/native staging is unavailable;
  report staging failures separately and invalidate older pending candidates.
- Preflight the internal Podkop generator without executing its CLI. Share the
  native generation contract across 0.7.14 and 0.7.22 without version branches.
- Retain transaction/backup hashes, staged sing-box validation and ownership checks;
  validate the old generated configuration before a rollback writes live UCI.
- Display versions and per-operation diagnostics in LuCI; APK dependencies remain
  unversioned for Podkop/sing-box.

## 0.2.0-r2 — 2026-10-18

- Synchronize the public sources with the deployed v0.2 implementation, retaining
  the stock public compatibility profile and excluding local device adaptations.
- Replace the unavailable `abs()` call in health clock-drift detection with signed
  comparisons; reset stale observations after forward/backward clock jumps.
- Serialize scheduled fetch/check and due through bounded priority reservations;
  coalesce duplicate jobs and retain private bounded execution receipts in tmpfs.
- Allow one optional `antigravity` Proxy section alongside MAIN and Exclusions.
  Bind its profile to a subscription stable ID, refresh it during native apply
  and recovery, and restore it during rollback while preserving independent routes.
- Keep MAIN preference, selector and failover independent of the additional route.
  Missing bound IDs, profile drift and unknown Proxy/VPN/Block sections fail closed.
- Preserve the existing one-MAIN installation, defaults, automation schedules and
  public stock-init checks. Add focused optional-route and clock-jump regressions.

## 0.2.0-r1

- Experimental preferred/reserve recovery, bounded minute health monitoring,
  failback controls, hourly statistics and native Exclusion preservation.

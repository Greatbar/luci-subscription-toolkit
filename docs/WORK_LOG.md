# Publication preparation log

The operator authorized extraction of r6, GPL-2.0-only licensing of original work,
public branding as LuCI Subscription Toolkit, and one initial local commit.
No router operations, source repository writes, publication, or subagents.

Decisions:
- Keep existing internal UCI/RPC/state paths for r6 compatibility; rename public
  package metadata and displayed product name only. Block co-installation.
- Replace private provider evidence with synthetic fixtures.
- Replace historical private APK upgrade tests with synthetic schema migration
  tests. These do not certify actual r2/r3 binary upgrades.
- Export addon ownership regressions without exporting FlowPilot support tooling.
- Perform author self-review because the operator prohibited subagents.

Progress:
- Source allowlist copied to independent staging directory.
- Original LuCI harness passes before and after public branding change.
- Public source archive checksums obtained; preparing autonomous test userspace.

Publication blockers resolved during preparation:
- Native APK builds depended on checkout mtimes: the regression failed with two
  different hashes, then passed after timestamp/permission normalization.
- The historical sing-box init fingerprint was local, not official: the public
  profile now pins the official init, preserving all ten Podkop fingerprints.
- Private stage2/r2/r3 APK paths and /work/node_modules were removed.
- Docker cp cannot write into the procd/tmpfs view: fixture files now use stdin.
- Synthetic stock packages need root ownership and correct file ownership;
  the sing-box init belongs to sing-box, not Podkop.
- Host-gateway synthetic endpoints were unreachable: fixtures now run inside
  the OpenWrt network namespace using a digest-pinned Python driver.
- Old timer tests changed signed r6 state without resealing it: only test clock
  adjustments now use the native state checksum; corruption tests remain intact.
- Old interrupted-marker tests expected blind restore: r6 correctly refuses
  unproven provenance. The public regression checks that refusal.

All adjustments above affect publication packaging/documentation/test fixtures.
No backend/model/routing algorithm changes were made.

Final test-driver corrections:
- Readiness replaces files atomically, preserving the running binary's inode.
- Browser runs in a digest-pinned official Playwright image in the namespace,
  avoiding unsupported host OS browser downloads and internal-network port mapping.
- Stock OpenWrt has passwd, not chpasswd; password setup and uhttpd restart are
  separate checked operations. The password is synthetic and lab-only.
- Standalone browser/readiness suites initialize a synthetic MAIN baseline.

Verified suites: model 69, service 15, provider/native check, LuCI harness,
integration 53, recovery 48, ownership 25, rotation 10, readiness and real browser.
Author self-review checked unchanged runtime/defaults, resource isolation,
metadata/payload ownership, licensing notices, public inputs and scoped exceptions.

Clean-clone finding: global core.autocrlf converted checkout files to CRLF,
changing APK contents and breaking shell scripts. Repository-local .gitattributes
now enforces LF for public text sources; the global Git setting is unchanged.
The unpublished initial commit is amended, retaining one root commit only.

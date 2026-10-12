# Publication security

Run `python3 -B tools/prepublish.py` after preparing the hash-pinned public tools.
This is the required gate before every authorized push or release. A nonzero exit
blocks publication. It never pushes, commits, tags, uploads, or accesses a router.

The gate rejects objects outside tools/publication-files.json, all source links,
hardlinks and special files. Only the exact top-level local directories .git,
.build, dist, node_modules, test-results and playwright-report are excluded from
source packaging; a nested directory with any of these names is not excluded.
The managed workspace may expose empty read-only .agents, .codex and .aws
placeholders; they qualify only while empty, and are never archive members.
Local directories are not publication inputs. dist has a separate strict policy.

A temporary Git index and object store freeze the inspected candidate as an
immutable Git tree without changing repository objects, index or refs. This
supports verification before an authorized commit. The receipt identifies that
candidate tree; it does not assert that the current HEAD contains uncommitted
changes. After an authorized commit, rerun the gate and verify the same tree ID.
All existing Git objects, including unreachable objects and metadata, are scanned.
Install the pre-push guard in each clone with `git config core.hooksPath .githooks`.
It invokes the same command with --require-head and rejects uncommitted candidates.
Build and audit executables must match the hash-pinned public tool archives.

APK files come only from tools/payload.json and immutable Git blobs. Payload
source hashes and installed permissions are fixed in that manifest. The SDK
Makefile calls the same staging command; PODKOP_TOOLS_SOURCE must refer to this
controlled checkout. Recursive root/htdocs copies are forbidden.

prepublish runs deterministic fixture verification, Gitleaks and independently
scoped address/credential checks, builds and extracts the APK, compares every
payload byte and mode, checks metadata/install scripts, and checks deterministic
source archive bytes. The exact release set is the addon APK, corresponding
source tar.gz and SHA256SUMS. Extra files, directories or links block the gate.
No lab image, fixture key, dependency package or audit report is a release asset.

Fixtures are constructed from constants in tools/generate-fixtures.py. The domain
is reserved .invalid, the UUID is deliberately fixed, and the Reality public-key
bytes are the public sequence 0 through 31. No subscription or router input is
read. Run with --check to require exact bytes; omit it to regenerate both files.
There is no Reality private key in the fixtures. The audit also requires every
historical fixture blob to equal a complete deterministic construction of the
current schema or the initial synthetic TLS schema; unknown fields or bytes fail.

The gate protects accidental inclusion, not deliberate modification of the gate
or its reviewed manifests. Review changes to these security files before use.
Runtime extension files and their defaults are outside this infrastructure change.

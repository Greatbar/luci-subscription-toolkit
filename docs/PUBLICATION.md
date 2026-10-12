# Publication procedure

Prepare publication from reviewed, committed sources. The required gate is
`python3 -B tools/prepublish.py --require-head`: its immutable candidate tree
must equal the HEAD tree, and any nonzero exit blocks publication.
Local preparation does not authorize a public repository, push, tag, release,
or router installation. Each of those operations requires separate authorization.

1. Review the complete security and runtime diff. Run `python3 -B tests/run.py all`;
   this includes the audit and publication attack regressions.
2. Run `python3 -B tools/prepublish.py` before committing. Review and commit only
   the files in tools/publication-files.json. Never upload the working directory
   recursively or include ignored local artifacts.
3. Install the local guard in each clone: `git config core.hooksPath .githooks`.
4. Run `python3 -B tools/prepublish.py --require-head` on the new HEAD. Check that
   `.build/prepublish.json` records the same tree as `git rev-parse HEAD^{tree}`.
   The pre-push hook runs this same gate.
5. Run `python3 -B tests/reproducibility.py`. Both clean candidate clones must
   produce identical APK bytes and match the APK in dist. Check that tracked Git
   state is clean and that dist contains exactly the three approved regular files.
6. Only then perform separately authorized repository creation/push/tag/release.
   Upload exactly the addon APK, corresponding source tar.gz and SHA256SUMS named
   by prepublish. No glob-based attachment selection. Extra objects block the gate.
7. Repeat the gate and checks after any source change. Preserve corresponding
   sources, build scripts, licenses and notices with every published artifact.

The hook and release procedure guard these publication paths; bypassing the hook
or uploading other files is not approved. Audit receipts, test screenshots and
lab fixtures are local evidence, not release attachments. Migration or
installation on an existing router is a separate operation.

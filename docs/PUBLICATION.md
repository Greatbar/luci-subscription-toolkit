# Publication procedure

The corrected working candidate is verified without a commit. Its immutable Git
tree ID and release hashes are recorded by `python3 -B tools/prepublish.py`.
The existing initial HEAD does not yet contain these infrastructure fixes.
No push, public repository, tag, release or router installation is authorized.

After separate operator authorization:
1. Run `python3 -B tools/prepublish.py`. Any nonzero exit blocks publication.
2. Review and commit only the files in tools/publication-files.json. Never use a
   recursive upload of the working directory or ignored local artifacts.
3. Install the local guard in each clone: `git config core.hooksPath .githooks`.
4. Run `python3 -B tools/prepublish.py --require-head`; verify that its candidate
   tree equals the committed HEAD tree. The pre-push hook runs this same command.
5. Only then perform the separately authorized repository creation/push/tag.
6. Upload exactly the three filenames emitted by prepublish: the addon APK,
   corresponding source tar.gz and SHA256SUMS. No glob-based attachment selection.
   A release directory containing any extra object is rejected by prepublish.
7. Repeat this gate for every subsequent push and release. Preserve corresponding
   sources, build scripts, licenses and notices with each release.

The hook and release procedure prevent accidental publication through these
paths; deliberately bypassing the hook or uploading other files is not approved.
Migration or installation on an existing router is a separate operation.

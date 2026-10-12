# Local publication proposal / план публикации

No remote, push, public repository, release, APK upload or router installation has
been performed. The local initial commit is the publication candidate.

After separate operator authorization:
1. Create a public repository named luci-subscription-toolkit under the selected
   account, using the standalone name and explicit independent compatibility text.
2. Push the audited initial commit and run build/tests from a clean checkout.
3. Review the compatibility limits and GPL/third-party notices. Preserve complete
   corresponding sources and build scripts alongside each addon release.
4. Tag 0.1.0-r6 and publish only the addon APK, SHA256SUMS and corresponding source.
   Do not attach Docker images, dependency binaries, private reports or lab outputs.
5. For subsequent releases, repeat file/history/payload secret audit and clean-build
   comparison; add compatibility profiles only after testing their exact upstream files.

Any future migration of an installed luci-app-podkop-tools is a separate operational
step. Co-installation is blocked, and no migration commands were run on a router.

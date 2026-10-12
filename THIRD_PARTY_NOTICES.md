# Licensing and provenance

Original extension, standalone packaging and tests: Copyright (C) 2026
LuCI Subscription Toolkit contributors. Licensed under GPL-2.0-only; see LICENSE.
The operator confirmed authority to license the original work under these terms.
The enclosing FlowPilot project's Apache-2.0 LICENSE is not this package's license.

## Included work

The r6 backend/model/shell scripts originally carry GPL-2.0-only identifiers.
LuCI views, original packaging scripts and tests are supplied by the same project
and licensed under GPL-2.0-only with the operator's authorization. Publication
changes are dated 2026-10-12 and limited to public branding, reproducible packaging,
public compatibility profile, autonomous fixtures/test drivers and documentation.
No FlowPilot controller, support implementation, private configurations or original
Git objects are distributed.

The complete GPL-2.0 license text is copied without modification from Podkop's
public 0.7.22 LICENSE. Its presence does not make the extension an official product.

## Podkop (runtime and fetched test source)

https://github.com/itdoginfo/podkop at tag 0.7.22, revision
c0a2736bb95884c19fedf638345ed6148c5fd6af. The upstream package metadata declares
GPL-2.0-or-later. Copyright notices and LICENSE remain in downloaded source.
The addon executes hash-verified functions from an installed Podkop; its APK does
not include those sources. The lab uses unmodified upstream files, with the usual
package-version substitution. Podkop's separate trademark policy is preserved in
upstream downloads and referenced at
https://github.com/itdoginfo/podkop/blob/main/TRADEMARK.md.
No Podkop logo is included. Its name is used only for factual compatibility/origin.

## OpenWrt and LuCI (runtime/test dependencies)

https://openwrt.org/ and https://github.com/openwrt/luci . These projects contain
components under multiple licenses, including GPL-2.0 and permissive licenses.
Their programs/assets are not copied into the addon payload. Hash-pinned rootfs
and dependency APKs are fetched only into ignored local build directories.
The official sing-box init script, downloaded at openwrt/packages revision
54d77dd5714bb4747c4bf061735304d18076de0b, is used only in the local test package;
OpenWrt packaging/source notices must accompany redistribution of such artifacts.
The test image and its dependency APKs are not release assets.

## sing-box (runtime/test dependency)

https://github.com/SagerNet/sing-box , v1.14.2, GPL-3.0-or-later.
The official binary is downloaded only for the isolated lab, never embedded in
this addon. Releasing it or the lab image would require a separate audit of its
complete corresponding source and dependency notices. This publication releases
only this extension and its source/build scripts; it does not sublicense sing-box.

## Other tools

Python, Node.js, fakeroot and native apk-tools are external build tools.
Playwright 1.58.2 is an Apache-2.0 test-only dependency installed with npm; its
license stays in node_modules and is not incorporated into the extension.
Gitleaks 8.24.3 is an MIT-licensed audit tool, downloaded separately and not shipped.
Fixtures contain reserved example addresses and deliberately synthetic credentials.

## Referenced ideas, not vendored implementations

Original development notes cite subscription parsing/config validation and bounded
throughput ideas from:
- https://github.com/itdoginfo/podkop/pull/325
- https://github.com/itdoginfo/podkop/pull/388
- https://github.com/itdoginfo/podkop/pull/445
- https://github.com/SagerNet/sing-box/pull/4398

A direct line comparison found no matching consecutive block longer than two
lines between the addon backend/model/views and these PR additions. This supports
an independent implementation, but is not a proof of authorship or an exhaustive
semantic plagiarism detector. The operator's rights confirmation and existing
SPDX notices are the licensing basis. See docs/provenance-comparison.json.

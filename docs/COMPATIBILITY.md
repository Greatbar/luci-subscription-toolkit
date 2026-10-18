# Compatibility profile / профиль совместимости

- OpenWrt 25.12.5 userspace, x86_64 Docker test namespace, host kernel.
- Unmodified public Podkop 0.7.22 source at
  `c0a2736bb95884c19fedf638345ed6148c5fd6af`; normal package substitution of
  `__COMPILED_VERSION_VARIABLE__` with `0.7.22`.
- Official sing-box 1.14.2 linux-amd64-musl binary for the lab.
- Official OpenWrt sing-box init script from openwrt/packages revision
  `54d77dd5714bb4747c4bf061735304d18076de0b`, also byte-identical to the init script
  in the public sing-box 1.13.21-r1 APK used for test-image preparation.

The standalone profile pins the official public init script. Local device
adaptations and their fingerprints are not shipped in the public package.
All ten Podkop implementation hashes match the public source byte-for-byte.
Runtime algorithms, internal filenames, RPC/UCI interfaces and state schemas stay
at the historical r6 baseline; v0.2 adds the documented policy and history extensions. The package name and displayed product titles change for independent branding.

A public build does not certify the home installation or an arbitrary device.
The addon fails closed on incompatible files or a sing-box version mismatch.
The lab's synthetic Podkop/sing-box APKs supply minimal dependency metadata;
they are test artifacts and must never be installed on a router. The addon APK
contains neither Podkop nor sing-box binaries or init scripts.

Для production нужен отдельно подготовленный пакет sing-box 1.14.2 с указанным
официальным init и необходимыми build tags. Обычный feed 25.12.5 с 1.13.21
не подходит. Расширение не устанавливает и не заменяет зависимости скрыто.

## Experimental hardware validation limit

The public APK has not yet been tested on a real router with the official
sing-box init script. The 22.7-second result for all three checks on 11 servers
comes from a local AX6S installation with a different init fingerprint. Earlier
OpenWrt lab coverage and focused batch checks do not certify public-APK hardware
installation. Required versions remain OpenWrt 25.12.5, Podkop 0.7.22 and
sing-box 1.14.2 with the pinned official init and uTLS/Clash API support.

# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 LuCI Subscription Toolkit contributors
include $(TOPDIR)/rules.mk
PKG_NAME:=luci-app-subscription-toolkit
PKG_VERSION:=0.3.0
PKG_RELEASE:=0
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE
PKGARCH:=all
PODKOP_TOOLS_SOURCE?=$(TOPDIR)/package/luci-app-subscription-toolkit
include $(INCLUDE_DIR)/package.mk
define Package/luci-app-subscription-toolkit
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Subscription Toolkit (compatible with Podkop)
  CONFLICTS:=luci-app-podkop-tools
  DEPENDS:=+podkop +sing-box +luci-base +rpcd +ucode +ucode-mod-fs +ucode-mod-uci +liblucihttp-ucode +curl +jq +bind-dig +coreutils-timeout +coreutils-nohup
endef
define Package/luci-app-subscription-toolkit/conffiles
/etc/config/podkop_tools
/etc/config/podkop_tools_subscription
endef
define Build/Compile
endef
define Package/luci-app-subscription-toolkit/install
  python3 -B "$(PODKOP_TOOLS_SOURCE)/tools/build-podkop-tools.py" --stage-only --output "$(1)"
endef
define Package/luci-app-subscription-toolkit/postinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT:-}" ] || exit 0
exec /usr/share/podkop-tools/post-install
endef
define Package/luci-app-subscription-toolkit/prerm
#!/bin/sh
[ -z "$${IPKG_INSTROOT:-}" ] || exit 0
exec /usr/share/podkop-tools/pre-deinstall
endef
$(eval $(call BuildPackage,luci-app-subscription-toolkit))

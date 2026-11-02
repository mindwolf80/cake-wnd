include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=cake-wnd
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

# Ships its own sch_cake.ko over the stock one (installed with --force-overwrite),
# so kmod-sched-cake stays installed and sqm-scripts' dependency stays satisfied.
define KernelPackage/sched-cake-wnd
  SUBMENU:=Network Support
  TITLE:=CAKE with TCP receive-window clamping
  DEPENDS:=+kmod-sched-core +kmod-nf-conntrack
  FILES:=$(PKG_BUILD_DIR)/sch_cake.ko
endef

define KernelPackage/sched-cake-wnd/description
 Drop-in sch_cake.ko that clamps the advertised TCP window of flows
 whose ingress sojourn time climbs. Off by default (wnd_clamp=0).
endef

# Overwrites stock's /etc/modules.d/sched-cake so boot-time kmodloader passes the parameters.
define KernelPackage/sched-cake-wnd/conffiles
/etc/modules.d/sched-cake
endef

define KernelPackage/sched-cake-wnd/install
	$(INSTALL_DIR) $(1)/etc/modules.d
	echo "sch_cake wnd_clamp=0 wnd_min_bytes=5792 wnd_hold_ms=200" \
		> $(1)/etc/modules.d/sched-cake
endef

define Build/Compile
	$(MAKE) -C "$(LINUX_DIR)" $(KERNEL_MAKE_FLAGS) M="$(PKG_BUILD_DIR)" modules
endef

$(eval $(call KernelPackage,sched-cake-wnd))

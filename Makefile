# pk's OS - a small Linux OS that runs from a live USB and also installs to disk.
#
#   make doctor      check dependencies (tells you what to install)
#   make iso         build build/pkos.iso
#   make run         live boot in QEMU (BIOS) -> console in terminal
#   make run-efi     live boot in QEMU (UEFI/OVMF)
#   make test        end-to-end auto test: live boot -> install to disk -> installed boot
#   make usb USB=/dev/sdX   write the ISO to a pendrive (dd)
#   make kernel      build your own custom kernel (optional, slow)
#   make clean       build/ delete
#
# Builds as a user; whichever step needs root (losetup/depmod) takes sudo itself.

SHELL       := /bin/bash
export PK_ROOT := $(CURDIR)
BUILD       := $(PK_ROOT)/build
WORK        := $(BUILD)/work
STAMP       := $(WORK)/.stamps
REPRODUCIBLE ?= 0
ifeq ($(REPRODUCIBLE),1)
export SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct 2>/dev/null || echo 1700000000)
endif

OUT         ?= $(BUILD)/pkos.iso
export OUT
ISO         := $(OUT)
TESTDISK    := $(BUILD)/testdisk.img

# ---- knobs (override from the command line) --------------------------------
SUDO          ?= sudo
QEMU          ?= qemu-system-x86_64
PK_KERNEL  ?=
PK_MODULES ?=
PK_BUSYBOX ?=
SQUASH_COMP   ?= auto
# canonical default must match config/live.conf (consoleblank: black-screen fix)
KERNEL_CMDLINE?= quiet loglevel=3 consoleblank=0 vt.global_cursor_default=1
PK_QEMU_MEM?= 2048
export SUDO QEMU PK_KERNEL PK_MODULES PK_BUSYBOX SQUASH_COMP KERNEL_CMDLINE PK_QEMU_MEM

SRC := $(shell find $(PK_ROOT)/rootfs $(PK_ROOT)/scripts $(PK_ROOT)/init $(PK_ROOT)/config -type f 2>/dev/null | tr '\n' ' ')

.PHONY: all help doctor live squash initrd iso runtime runtime-desktop apps-iso manifest manifest-apps kit verify check gui-test bundle run run-tty run-iso run-efi test test-live test-apps usb kernel clean clean-rootfs clean-runtime deepclean rootfs

all: iso

help:
	@echo "pk's OS build system - targets:"
	@echo "  make doctor     dependencies check"
	@echo "  make iso        --> $(ISO)"
	@echo "  make run        live boot in QEMU (serial + direct kernel boot when headless)"
	@echo "  make run-iso    full ISO+GRUB boot in QEMU (needs a display)"
	@echo "  make run-efi    UEFI live boot in QEMU"
	@echo "  make test       auto end-to-end QA (8 stages: live, install, installed, toram,"
	@echo "                      UEFI, persistence+net+ssh, apps, pendrive kit)"
	@echo "  make check      only stage 8 (pk-check + keymap + install+user+runtime)"
	@echo "  make gui-test   stage 8 + desktop session (weston/Xvfb + xterm round-trip)"
	@echo "  make apps-iso   base ISO + App Runtime inside  -> build/pkos-apps.iso"
	@echo "  make manifest   ISO payload hashes (build/manifest.txt) -> rebuild verify"
	@echo "  make verify     verify ISO/USB from manifest (tools/verify-usb.sh)"
	@echo "  make bundle     git bundle + source tar (to survive a sandbox reset)"
	@echo "  sudo make runtime   # App Runtime (Debian squashfs) -> build/pk-runtime.sqfs"
	@echo "                      # VARIANT=lean|desktop|full|dev   PKGS=wine,firefox-esr"
	@echo "  sudo make runtime-desktop   # GUI runtime (weston+Xvfb+xterm+mesa+wine)"
	@echo "  make iso WITH_RUNTIME=1   # runtime inside the ISO (/live/pk-runtime.sqfs)"
	@echo "  make test-apps    QA of the apps layer (14 checks; REAL_RUNTIME=1 / WINE=1 too)"
	@echo "                      # PK_TEST_REAL_RUNTIME=1 make test-apps  (with real Debian)"
	@echo "                      # boot option: pk_runtime=off|auto|<dev|file>  pk_apps_get=<pkg>"
	@echo "  make usb USB=/dev/sdX    dd the ISO to USB"
	@echo "  make kernel     build your own kernel (build/kernel-<ver>), then:"
	@echo "                      make clean-rootfs && make iso PK_KERNEL=... PK_MODULES=..."
	@echo "  make clean"
	@echo "notes:"
	@echo "  make iso REPRODUCIBLE=1   # byte-stable squashfs/initrd via SOURCE_DATE_EPOCH"
	@echo "  console keymaps need 'kbd' on the builder (else pk-keymap is GUI-only)"

doctor:
	@scripts/doctor.sh

# ---------------------------------------------------------------- stages
rootfs live: $(STAMP)/rootfs

$(STAMP)/rootfs: $(SRC)
	@mkdir -p $(STAMP) $(WORK)
	@scripts/build-rootfs
	@touch $@

squash: $(STAMP)/squash
$(STAMP)/squash: $(STAMP)/rootfs
	@mkdir -p $(STAMP)
	@scripts/mk-squashfs
	@touch $@

initrd: $(STAMP)/initrd
$(STAMP)/initrd: $(STAMP)/rootfs $(PK_ROOT)/init/init $(PK_ROOT)/init/kernel-modules
	@mkdir -p $(STAMP)
	@scripts/mk-initrd
	@touch $@

# app runtime: build/pk-runtime.sqfs (+ rw img) - for Linux/Windows apps
runtime:
	@sh scripts/make-runtime $(if $(strip $(VARIANT)),--variant=$(VARIANT),) $(if $(strip $(PKGS)),--pkgs=$(PKGS),)
runtime-desktop:
	@sh scripts/make-runtime --variant=desktop --rw-mb=$(or $(RWMB),2048)
apps-iso: iso
	@OUT=$(BUILD)/pkos-apps.iso PK_RUNTIME_IMG=$(or $(RUNTIME_IMG),$(BUILD)/pk-runtime.sqfs) WITH_RUNTIME=1 scripts/mk-iso
	@echo "[pk] apps ISO: $(BUILD)/pkos-apps.iso"
manifest: iso
	@scripts/manifest.sh $(ISO) $(BUILD)/manifest.txt
manifest-apps: apps-iso
	@scripts/manifest.sh $(BUILD)/pkos-apps.iso $(BUILD)/manifest-apps.txt
kit: iso apps-iso manifest manifest-apps bundle
	@echo "[pk] kit ready: build/pkos.iso build/pkos-apps.iso build/manifest*.txt build/pkos-main.bundle"
	@echo "[pk] pendrive: tools/write-usb.sh  or  dd  (docs/PENDRIVE.md)"
verify: manifest
	@tools/verify-usb.sh --iso $(ISO) $(BUILD)/manifest.txt
check: iso
	@PK_TEST_STAGES=8 $(MAKE) test
gui-test: iso
	@PK_TEST_STAGES=8 PK_TEST_GUI=1 $(MAKE) test
bundle:
	@git bundle create $(BUILD)/pkos-main.bundle --all >/dev/null 2>&1 || true
	@tar --exclude=build --exclude=.git -czf $(BUILD)/pkos-src.tar.gz -C .. pkos 2>/dev/null || true
	@echo "[pk] bundle: $(BUILD)/pkos-main.bundle  +  $(BUILD)/pkos-src.tar.gz"
	@echo "[pk] copy both to /home/user (to persist): cp $(BUILD)/pkos-*.tar.gz $(BUILD)/pkos-main.bundle .."
clean-runtime:
	@rm -f $(BUILD)/pk-runtime.sqfs $(BUILD)/pk-runtime-rw.img
	@echo "runtime images removed (rebuilt by make runtime)"

iso: $(ISO)
$(ISO): $(STAMP)/squash $(STAMP)/initrd $(PK_ROOT)/init/grub.cfg $(PK_ROOT)/config/live.conf
	# ^ grub.cfg/live.conf are prerequisites because: if these change (KERNEL_CMDLINE, menu entries)
	#   the old ISO gets rebuilt, otherwise a stale image would ship (a real footgun).
	@scripts/mk-iso
	@touch $@

# refresh the rootfs (after changing config/live.conf or the kernel)
clean-rootfs:
	@rm -f $(STAMP)/rootfs $(STAMP)/squash $(STAMP)/initrd
	@echo "stamps cleared - next 'make iso' rebuilds the rootfs"

# ---------------------------------------------------------------- run / test
run: iso
	@scripts/run-qemu.sh -iso $(ISO) -tty -auto

run-tty: iso
	@scripts/run-qemu.sh -iso $(ISO) -tty

run-iso: iso
	@scripts/run-qemu.sh -iso $(ISO) -tty

run-efi: iso
	@scripts/run-qemu.sh -iso $(ISO) -tty -uefi

test-apps: iso
	@PK_TEST_STAGES=7 $(MAKE) test

test: iso
	@scripts/run-test.sh $(ISO) $(TESTDISK)

test-live: iso
	@PK_TEST_SKIP_INSTALL=1 scripts/run-test.sh $(ISO) $(TESTDISK)

# ---------------------------------------------------------------- USB
usb:
	@test -n "$(USB)" || { echo "usage: make usb USB=/dev/sdX  (whole device, not a partition)"; exit 1; }
	@tools/write-usb.sh $(USB) $(ISO)

# ---------------------------------------------------------------- optional custom kernel
kernel:
	@scripts/build-kernel

clean:
	@rm -rf $(WORK) $(ISO) $(TESTDISK) $(BUILD)/*.log $(BUILD)/test-logs
	@echo "build/work and build/*.iso deleted"

deepclean: clean
	@rm -rf $(BUILD)
	@echo "delete the whole build/"

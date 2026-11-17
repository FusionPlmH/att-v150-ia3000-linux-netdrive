# Build helpers for att-v150-ia3000-linux-netdrive.
#
#   make                 build both modules against the running kernel
#   make KDIR=/path      build against another kernel tree
#   make clean           remove build output
#
# Installing is install.sh's job: module placement, modprobe options, the
# systemd unit and the host VLAN interfaces all live there. See README.md.

KDIR ?= /lib/modules/$(shell uname -r)/build

.PHONY: all modules clean help

all: modules

modules:
	@test -e "$(KDIR)/Makefile" || { \
		echo "no kernel build tree at $(KDIR)" >&2; \
		echo "install kernel headers first (see README / install.sh)" >&2; \
		exit 1; }
	$(MAKE) -C "$(KDIR)" M="$(CURDIR)/kernel" modules

clean:
	$(MAKE) -C "$(KDIR)" M="$(CURDIR)/kernel" clean 2>/dev/null || true
	rm -f kernel/*.o kernel/*.ko kernel/*.mod kernel/*.mod.c kernel/.*.cmd
	rm -rf kernel/.tmp_versions
	rm -f kernel/Module.symvers kernel/modules.order

help:
	@sed -n '2,10p' Makefile | sed 's/^# \{0,1\}//'

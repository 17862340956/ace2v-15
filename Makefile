obj-m += cpuinfo_spoof.o
# Real private proc types are compiled from the pinned 901 source tree.
ccflags-y += -Werror=incompatible-pointer-types -g -gdwarf-4 -fno-eliminate-unused-debug-types
ccflags-y += -I$(srctree)/fs/proc
KDIR ?= $(error KDIR must point to the completed 901 kernel output)
MDIR := $(realpath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
all:
	$(MAKE) -C $(KDIR) M=$(MDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(MDIR) clean

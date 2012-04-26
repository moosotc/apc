.PHONY: itc-all itc-build-module itc-install-module

itc-all:: itc-build-module

KVERSION  ?= $(shell uname -r)
KDIR      ?= /lib/modules/$(KVERSION)/build
OUTDIR    ?= /lib/modules/$(KVERSION)/misc

MM        := $(shell echo $(KVERSION) | cut -d. -f1,2)
MM        := 3.0
ifeq ($(MM),2.4)
KMOD_SUFFIX := .o
K24         := defined
else
ifeq ($(MM),2.6)
KMOD_SUFFIX := .ko
else
ifneq ($(MM),3.0)
$(error Only 2.4, 2.6, 3.0 kernel series are supported. You have "$(MM)")
endif
endif
endif

itc-objs := itc-mod.o

hack := $(shell $(CC) -print-search-dirs | sed -n 's;^install: \(.*\);\1include;p;q')
export CPATH:=${CPATH}:${hack}

obj-m := itc.o

ifdef K24
itc.o: $(itc-objs)
	$(LD) $(EXTRA_LDFLAGS) -o $@ -r $(itc-objs)

include $(KDIR)/Rules.make
endif

$(KDIR)/Makefile:
	@echo Cannot build module, kernel sources are probably not installed
	@exit 1

$(KDIR)/.config:
	@echo Cannot build module, kernel is not configured
	@exit 1

itc-build-module:: $(KDIR)/Makefile $(KDIR)/.config
	$(MAKE) -C $(KDIR) modules SUBDIRS=$(CURDIR) M=$(CURDIR)

itc-install-module:: itc-build-module
	mkdir -p $(OUTDIR)
	install -m 0400 -o 0 -g 0 itc$(KMOD_SUFFIX) $(OUTDIR)

V ?= 0
ifeq ($(V),0)
.SILENT:
endif

PWD := $(shell pwd)

O :=
ifeq ($(O),)
$(error "O variable must be set to the output directory")
endif

initrd rootfs:
	$(MAKE) -C "$(PWD)/$@" V=$V O=$O

.PHONY: initrd rootfs
V ?= 0
ifeq ($(V),0)
.SILENT:
endif

PWD := $(shell pwd)

O :=
ifeq ($(O),)
$(error "O variable must be set to the output directory")
endif

DIRS := $(shell find . -maxdepth 1 -type d -not -name .)

$(DIRS):
	$(MAKE) -C "$(PWD)/$@" V=$V O=$O all

.PHONY: $(DIRS)
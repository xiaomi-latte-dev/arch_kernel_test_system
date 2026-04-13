V ?= 0
ifeq ($(V),0)
.SILENT:
endif

O :=
ifeq ($(O),)
$(error "O variable must be set to the output directory")
endif

install-files += init

all:
	rm -f "$(O)/linuxrc"
	for f in $(install-files);do \
		sudo install -Dm755 "$$f" "$(O)/$$f"; \
	done

.PHONY: all

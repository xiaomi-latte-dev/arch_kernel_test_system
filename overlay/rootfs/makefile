V ?= 0
ifeq ($(V),0)
.SILENT:
endif

O :=
ifeq ($(O),)
$(error "O variable must be set to the output directory")
endif

SED := sudo sed -i

ROOT_FILES_SRC +=
ROOT_DIRS += etc usr
# 搜索 ROOT_DIRS 中的文件递归添加到 ROOT_FILES_SRC
$(foreach dir,$(ROOT_DIRS),$(eval ROOT_FILES_SRC += $(shell find $(dir) -type f)))
ROOT_FILES_DST := $(patsubst %,$(O)/%,$(ROOT_FILES_SRC))

USER_FILES_SRC := $(shell find home -type f)
USER_FILES_DST := $(patsubst home/%,$(O)/home/%,$(USER_FILES_SRC))

$(ROOT_FILES_DST): $(O)/%: %
	sudo install -Dm755 "$<" "$@"

$(USER_FILES_DST): $(O)/home/%: home/%
	sudo install -Dm755 -o1000 -g1000 "$<" "$@"

post-process:
	[ -f $(O)/etc/locale.gen ] && $(SED) 's/#zh_CN.U/zh_CN.U/' $(O)/etc/locale.gen
	[ -f $(O)/etc/pacman.conf ] && $(SED) 's/#Color/Color/' $(O)/etc/pacman.conf
	[ -f $(O)/etc/sudoers ] && $(SED) 's/# %wheel ALL=(ALL:ALL) N/%wheel ALL=(ALL:ALL) N/' $(O)/etc/sudoers

all: $(ROOT_FILES_DST) $(USER_FILES_DST) post-process
	
.PHONY: all post-process

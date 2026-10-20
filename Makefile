V ?= 0
ifeq ($(V),0)
.SILENT:
endif

# O 是 ESP 根目录（最终交付物），默认 out/
# 所有中间产物（pacstrap 目录、解包目录、rpm、stamp）统一放 TMP_DIR，默认 tmp/
O ?= $(CURDIR)/out
TMP_DIR ?= $(CURDIR)/tmp
OVERLAY_DIR := $(CURDIR)/overlay
INITRD_DIR := $(TMP_DIR)/initrd
INITRD_KMOD_DIR := $(TMP_DIR)/initrd_kmod
ROOTFS_DIR := $(TMP_DIR)/rootfs
KERNEL_DIR := $(TMP_DIR)/kernel
SHIM_GRUB_DIR := $(TMP_DIR)/shim_grub

INITRD_FILE := $(O)/initrd.cpio.gz
INITRD_KMOD_FILE := $(O)/initrd_kmod.cpio.gz
INITRD_PACKAGES += busybox

KERNEL_OUT_FILE := $(O)/vmlinuz
KERNEL_MODULES_FILE := $(O)/kernel_modules.cpio.gz

ROOTFS_FILE := $(O)/system.sfs
ROOTFS_PACKAGES += base bash-completion linux-firmware-broadcom linux-firmware-intel intel-ucode
ROOTFS_PACKAGES += sudo btop nano curl wget
ROOTFS_PACKAGES += exfatprogs dosfstools btrfs-progs pciutils usbutils
ROOTFS_PACKAGES += mesa libva-intel-driver noto-fonts-cjk
ROOTFS_PACKAGES += pipewire-pulse pipewire-alsa alsa-utils bluez bluez-utils networkmanager iio-sensor-proxy
ROOTFS_PACKAGES += irqbalance zram-generator openssh

DESKTOP := gnome
ifeq ($(DESKTOP),lxqt)
	ROOTFS_PACKAGES += sddm lxqt network-manager-applet
	ROOTFS_PACKAGES += gparted qterminal l3afpad falkon
else ifeq ($(DESKTOP),gnome)
	ROOTFS_PACKAGES += gdm gnome-shell gnome-shell-extension-appindicator gnome-backgrounds adw-gtk-theme gnome-control-center gnome-tweaks dconf-editor
	ROOTFS_PACKAGES += nautilus gvfs-smb gnome-console gnome-text-editor gnome-system-monitor seahorse ibus ibus-libpinyin gnome-remote-desktop
	ROOTFS_PACKAGES += gparted falkon gnome-sound-recorder snapshot vlc vlc-plugins-visualization vlc-plugin-ffmpeg
else
	$(error DESKTOP $(DESKTOP) is not supported)
endif

# 内核输入既支持 Arch pacman 包（make pacman-pkg 产物），也兼容旧的 tar.gz。
# 多个候选同时存在时优先使用 pacman 包。
KERNEL_PACKAGE_FILE := $(firstword $(wildcard *.pkg.tar.zst) $(wildcard kernel-*.tar.gz) \
			$(wildcard $(TMP_DIR)/*.pkg.tar.zst) $(wildcard $(TMP_DIR)/kernel-*.tar.gz))

# pacman 包内布局为 usr/lib/modules/<ver>/vmlinuz，旧 tarball 为根目录 vmlinuz-<ver>。
# 解包统一成 vmlinuz-<ver> + lib/modules/<ver> 的扁平布局。
KERNEL_VERSION ?= $(shell ./scripts/kernel-version.sh "$(KERNEL_PACKAGE_FILE)")
KERNEL_IMAGE_FILE := $(KERNEL_DIR)/vmlinuz-$(KERNEL_VERSION)

# pacman 包里的模块是 .ko.zst，busybox modprobe 不认，默认解压成 .ko
KERNEL_MODULE_DECOMPRESS ?= y

MOK_KEY := $(OVERLAY_DIR)/boot/EFI/MOK.key
MOK_CERT := $(OVERLAY_DIR)/boot/EFI/MOK.crt

# overlay 的文件在 create_rootfs 末尾才铺进 rootfs，overlay 一改 stamp 必须失效，
# 否则改 UCM/固件等不会生效。
OVERLAY_BOOT_FILES := $(shell find $(OVERLAY_DIR)/boot -type f 2>/dev/null)
OVERLAY_ROOTFS_FILES := $(shell find $(OVERLAY_DIR)/rootfs -type f 2>/dev/null)
OVERLAY_INITRD_FILES := $(shell find $(OVERLAY_DIR)/initrd -type f 2>/dev/null)

RM := sudo rm -rf
CP := sudo cp -r
CHMOD := sudo chmod -R 755
CHOWN := sudo chown -R 0:0
MKDIR := sudo mkdir -p
LN := sudo ln -sfn

MAKE := sudo make
OVERLAY := $(MAKE) -C $(OVERLAY_DIR) V=$V
CHROOT := sudo arch-chroot
PACSTRAP := sudo pacstrap -C pacman.conf -c

# Fedora 44 的 EFI/BOOT 目录直接提供 EFI 文件，无需解包 rpm。
# 注意该目录没有 fbx64.efi（Fedora 43 的 rpm 里有），因此不再安装它。
SHIM_BASE_URL := https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/EFI/BOOT

SHIM_BOOTX64 := $(SHIM_GRUB_DIR)/BOOTX64.EFI
SHIM_GRUBX64 := $(SHIM_GRUB_DIR)/grubx64.efi
SHIM_MMX64 := $(SHIM_GRUB_DIR)/mmx64.efi

$(SHIM_BOOTX64) $(SHIM_GRUBX64) $(SHIM_MMX64): | $(SHIM_GRUB_DIR)
	# 先下到临时文件再改名：wget 中断会留下截断文件。直接写目标会让 make 把
	# 截断文件当成已完成，后续签名和引导都基于坏文件。
	TMP_DL="$@.part"; \
	rm -f "$$TMP_DL"; \
	wget --quiet "$(SHIM_BASE_URL)/$(@F)" -O "$$TMP_DL"; \
	[ -s "$$TMP_DL" ] || { echo "下载失败: $@" >&2; rm -f "$$TMP_DL"; exit 1; }; \
	mv -f "$$TMP_DL" "$@"
# shim 在 .vendor_cert 段内嵌 fedoraca 证书，这是它信任 grub 的依据。
# 用它判断 grub 是否有「shim 认可的签名」，避免被本机系统密钥环（通常没有
# fedoraca）误判成未签名，从而每次都不必要地重签。
SHIM_VENDOR_CERT := $(SHIM_GRUB_DIR)/vendor.pem
$(SHIM_VENDOR_CERT): $(SHIM_BOOTX64) | $(SHIM_GRUB_DIR)
	./scripts/shim-vendor-cert.sh "$(SHIM_BOOTX64)" "$@"
SHIM_GRUB_STAMP := $(TMP_DIR)/.shim-grub_stamp
unpack_shim_grub $(SHIM_GRUB_STAMP): $(SHIM_BOOTX64) $(SHIM_GRUBX64) $(SHIM_MMX64)
	touch $(SHIM_GRUB_STAMP)
clean_shim_grub:
	$(RM) $(SHIM_GRUB_STAMP)
	$(RM) $(SHIM_GRUB_DIR)
.PHONY: unpack_shim_grub clean_shim_grub

INITRD_STRAP := $(TMP_DIR)/.initrd_strap
create_initrd $(INITRD_STRAP): $(OVERLAY_INITRD_FILES) | $(INITRD_DIR)
	$(MKDIR) "$(INITRD_DIR)/usr/sbin" "$(INITRD_DIR)/mnt" "$(INITRD_DIR)/sys_root"
	$(LN) /usr/bin "$(INITRD_DIR)/bin"
	$(LN) /usr/sbin "$(INITRD_DIR)/sbin"

	$(PACSTRAP) $(INITRD_DIR) $(INITRD_PACKAGES)

	$(CHROOT) $(INITRD_DIR) busybox --install -s
	$(CHROOT) $(INITRD_DIR) rm -rf /etc/pacman.d /usr/share/{man,doc} /var/cache /var/lib/pacman /var/log

	$(OVERLAY) O="$(INITRD_DIR)" initrd
	touch $(INITRD_STRAP)
initrd pack_initrd $(INITRD_FILE): $(INITRD_STRAP) | $(INITRD_DIR) $(O)
	cd $(INITRD_DIR) && find . | cpio -o -H newc | gzip > $(INITRD_FILE)
clean_initrd:
	$(RM) $(INITRD_STRAP)
	$(RM) $(INITRD_DIR)
	$(RM) $(INITRD_FILE)
initrd_shell: $(INITRD_STRAP) | $(INITRD_DIR)
	$(CHROOT) $(INITRD_DIR) ash
.PHONY: initrd initrd_shell clean_initrd

ROOTFS_STRAP := $(TMP_DIR)/.rootfs_strap
create_rootfs $(ROOTFS_STRAP): $(OVERLAY_ROOTFS_FILES) | $(ROOTFS_DIR)
	$(PACSTRAP) $(ROOTFS_DIR) $(ROOTFS_PACKAGES)

	$(CHROOT) $(ROOTFS_DIR) ln -sfn /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
	$(CHROOT) $(ROOTFS_DIR) groupadd -r autologin
	$(CHROOT) $(ROOTFS_DIR) useradd -m -G wheel,lp,autologin,video,render,input user
	echo "root:123456" | $(CHROOT) $(ROOTFS_DIR) chpasswd
	echo "user:123456" | $(CHROOT) $(ROOTFS_DIR) chpasswd
ifeq ($(DESKTOP),lxqt)
	$(CHROOT) $(ROOTFS_DIR) systemctl enable sddm
else ifeq ($(DESKTOP),gnome)
	$(CHROOT) $(ROOTFS_DIR) systemctl enable gdm
endif
	$(CHROOT) $(ROOTFS_DIR) systemctl enable NetworkManager
	$(CHROOT) $(ROOTFS_DIR) systemctl enable bluetooth
	$(CHROOT) $(ROOTFS_DIR) systemctl enable irqbalance
	$(CHROOT) $(ROOTFS_DIR) systemctl enable systemd-zram-setup@zram0.service
	$(CHROOT) $(ROOTFS_DIR) systemctl enable sshd
	$(CHROOT) $(ROOTFS_DIR) rm -rf /var/cache/pacman /var/lib/pacman/sync /var/log/*

	$(OVERLAY) O="$(ROOTFS_DIR)" rootfs
	$(CHROOT) $(ROOTFS_DIR) locale-gen

	touch $(ROOTFS_STRAP)
rootfs pack_rootfs $(ROOTFS_FILE): $(ROOTFS_STRAP) | $(ROOTFS_DIR) $(O)
	sudo mksquashfs "$(ROOTFS_DIR)"/* "$(ROOTFS_FILE)" -b 1M -comp lz4 -noappend
	sudo chmod 777 $(ROOTFS_FILE)
clean_rootfs: | $(ROOTFS_DIR)
	$(RM) $(ROOTFS_STRAP)
	$(RM) $(ROOTFS_DIR)
	$(RM) $(ROOTFS_FILE)
rootfs_shell: $(ROOTFS_STRAP) | $(ROOTFS_DIR)
	$(CHROOT) $(ROOTFS_DIR) bash
.PHONY: rootfs rootfs_shell clean_rootfs

unpack_kernel $(KERNEL_IMAGE_FILE): | $(KERNEL_DIR)
	./scripts/unpack-kernel.sh "$(KERNEL_PACKAGE_FILE)" "$(KERNEL_DIR)" "$(KERNEL_MODULE_DECOMPRESS)"

# pack_kernel 产出两样东西：模块 cpio 与可用于 Secure Boot 的内核。
# 内核输出为 $(O)/vmlinuz（固定名），签名也在这里完成，boot 只负责摆放。
pack_kernel kernel: $(KERNEL_MODULES_FILE) $(KERNEL_OUT_FILE)
	@:

$(KERNEL_MODULES_FILE): $(KERNEL_IMAGE_FILE) | $(KERNEL_DIR) $(O)
	cd $(KERNEL_DIR) && find . ! -name "vmlinuz*" | cpio -o -H newc | gzip > $(KERNEL_MODULES_FILE)

$(KERNEL_OUT_FILE): $(KERNEL_IMAGE_FILE) | $(KERNEL_DIR) $(O)
	# Secure Boot 下 shim 会校验内核签名：已由本仓库 MOK 签过就复用，否则重签。
	# 整个判断必须在一个 shell 块里，make 每行 recipe 都是独立 shell。
	KIMG="$(KERNEL_OUT_FILE)"; \
	if command -v sbverify >/dev/null 2>&1 && [ -f "$(MOK_CERT)" ] && \
	   sbverify --cert "$(MOK_CERT)" "$$KIMG" >/dev/null 2>&1; then \
		echo "内核已有有效 MOK 签名，复用" >&2; \
	else \
		cp "$(KERNEL_IMAGE_FILE)" "$$KIMG"; \
		if command -v sbsign >/dev/null 2>&1 && [ -f "$(MOK_KEY)" ] && [ -f "$(MOK_CERT)" ]; then \
			echo "内核未签名或签名不匹配，使用 MOK 重签" >&2; \
			sbsign --key "$(MOK_KEY)" --cert "$(MOK_CERT)" \
			       --output "$$KIMG.signed" "$$KIMG" && \
				mv "$$KIMG.signed" "$$KIMG"; \
		else \
			echo "警告：sbsign 或 MOK 密钥缺失，内核未签名，Secure Boot 下无法引导" >&2; \
		fi; \
	fi

clean_kernel:
	$(RM) $(KERNEL_DIR)
	$(RM) $(KERNEL_MODULES_FILE)
	$(RM) $(KERNEL_OUT_FILE)
.PHONY: unpack_kernel pack_kernel kernel clean_kernel

INITRD_KMOD_STRAP := $(TMP_DIR)/.initrd_kmod_strap
initrd_with_kmod create_initrd_kmod $(INITRD_KMOD_STRAP): $(KERNEL_IMAGE_FILE) $(INITRD_STRAP)| $(INITRD_KMOD_DIR) $(O)
	$(CP) "$(INITRD_DIR)"/* $(INITRD_KMOD_DIR)
	$(CP) "$(KERNEL_DIR)"/* $(INITRD_KMOD_DIR)

	touch $(INITRD_KMOD_STRAP)
initrd_kmod pack_initrd_kmod $(INITRD_KMOD_FILE): $(INITRD_KMOD_STRAP) | $(INITRD_KMOD_DIR)
	cd $(INITRD_KMOD_DIR) && find . ! -name "vmlinuz*" | cpio -o -H newc | gzip > $(INITRD_KMOD_FILE)
clean_initrd_kmod:
	$(RM) $(INITRD_KMOD_STRAP)
	$(RM) $(INITRD_KMOD_DIR)
	$(RM) $(INITRD_KMOD_FILE)
.PHONY: create_initrd_kmod initrd_with_kmod initrd_kmod clean_initrd_kmod

# boot：把 O 目录本身做成 ESP（EFI System Partition）布局
#   O/EFI/BOOT/BOOTX64.EFI   shim（微软签名的第一级引导）
#   O/EFI/BOOT/grubx64.efi   GRUB（由本仓库 MOK 私钥签名）
#   O/EFI/BOOT/mmx64.efi     shim 的 MOK 管理器
#   O/grub.cfg               由 grub.cfg.in 生成
#   O/vmlinuz                内核（固定名，由 pack_kernel 产出）
#   O/initrd.cpio.gz         基础 initrd
#   O/kernel_modules.cpio.gz 模块
#   O/system.sfs             根文件系统
BOOT_STAMP := $(TMP_DIR)/.boot_stamp

boot create_boot $(BOOT_STAMP): $(SHIM_VENDOR_CERT) $(SHIM_GRUB_STAMP) $(OVERLAY_BOOT_FILES) | $(O)
	mkdir -p "$(O)/EFI/BOOT"
	# shim 与 MOK 管理器：保持微软签名，不能重签。
	install -Dm644 "$(SHIM_BOOTX64)" "$(O)/EFI/BOOT/BOOTX64.EFI"
	install -Dm644 "$(SHIM_MMX64)" "$(O)/EFI/BOOT/mmx64.efi"
	# GRUB：官方 grubx64.efi 由 fedoraca 签名，配套 shim 可直接加载，此时原样拷贝；
	# 只有签名不被 shim 认可（或压根没签名）时才用本仓库 MOK 重签。
	# 注意不能用无参数的 sbverify 判断——它查的是本机系统密钥环，通常没有
	# fedoraca，会把官方签名误判为无效。
	GRUB_SRC="$(SHIM_GRUBX64)"; GRUB_DST="$(O)/EFI/BOOT/grubx64.efi"; \
	if command -v sbverify >/dev/null 2>&1 && [ -f "$(SHIM_VENDOR_CERT)" ] && \
	   sbverify --cert "$(SHIM_VENDOR_CERT)" "$$GRUB_SRC" >/dev/null 2>&1; then \
		echo "grubx64.efi 已由 fedoraca 签名，原样拷贝" >&2; \
		install -Dm644 "$$GRUB_SRC" "$$GRUB_DST"; \
	elif command -v sbsign >/dev/null 2>&1 && [ -f "$(MOK_KEY)" ] && [ -f "$(MOK_CERT)" ]; then \
		echo "grubx64.efi 未被 shim 认可，使用 MOK 重签" >&2; \
		sbsign --key "$(MOK_KEY)" --cert "$(MOK_CERT)" --output "$$GRUB_DST" "$$GRUB_SRC"; \
	else \
		echo "警告：grubx64.efi 签名不可用且 sbsign/MOK 缺失，Secure Boot 下无法引导" >&2; \
		install -Dm644 "$$GRUB_SRC" "$$GRUB_DST"; \
	fi
	# MOK 证书：用户需在 MOK 管理器里登记后才信任上面的签名
	install -Dm644 "$(OVERLAY_DIR)/boot/MOK.cer" "$(O)/MOK.cer"
	# 辅助工具
	install -Dm644 "$(OVERLAY_DIR)/boot/setup_var.efi" "$(O)/setup_var.efi"
	install -Dm644 "$(OVERLAY_DIR)/boot/linux-usb-daget_ssh_123456.efi" "$(O)/linux-usb-daget_ssh_123456.efi"
	# GRUB 的 prefix 指向 EFI/BOOT，只会读 EFI/BOOT/grub.cfg（已用 QEMU 实测），
	# 这里放重定向文件把它转给 ESP 根目录的 grub.cfg
	install -Dm644 "$(OVERLAY_DIR)/boot/EFI/Boot/grub.cfg" "$(O)/EFI/BOOT/grub.cfg"
	install -Dm644 "$(OVERLAY_DIR)/boot/grub.cfg.in" "$(O)/grub.cfg"
	touch $(BOOT_STAMP)
	echo "ESP 布局已生成: $(O)"
clean_boot:
	# boot 产物全部由当前用户生成在 $(O) 下，不需要 sudo
	rm -f $(BOOT_STAMP)
	rm -rf $(O)/EFI
	rm -f $(O)/grub.cfg $(O)/MOK.cer $(O)/setup_var.efi
	rm -f $(O)/linux-usb-daget_ssh_123456.efi
.PHONY: boot create_boot clean_boot

all: $(INITRD_FILE) $(KERNEL_MODULES_FILE) $(KERNEL_OUT_FILE) $(ROOTFS_FILE) $(BOOT_STAMP)
.PHONY: all

clean: clean_initrd clean_rootfs clean_kernel clean_initrd_kmod clean_boot
dist_clean: clean clean_shim_grub
.PHONY: clean dist_clean

QEMU_DEBUG := 0
KERNEL_DEFAULT_CMDLINE := console=ttyS0,115200 console=tty1 DEBUG=$(QEMU_DEBUG) video=1280x720 panic=0
EXTRA_KERNEL_CMDLINE := ROOT_SEARCH_FILES=/sbin/init quiet BIND_UPPER=1
QEMU_KERNEL_CMDLINE = $(KERNEL_DEFAULT_CMDLINE) $(EXTRA_KERNEL_CMDLINE)

KVM := y
QEMU_KVM :=
ifeq ($(KVM),y)
	QEMU_KVM := -enable-kvm
endif
QEMU_MEM := 2000
QEMU_KERNEL_FILE := $(KERNEL_IMAGE_FILE)
QEMU_INITRD_FILE := $(INITRD_KMOD_FILE)
QEMU_SYSTEM_FILE := $(ROOTFS_FILE)
qemu: $(QEMU_KERNEL_FILE) $(QEMU_INITRD_FILE) $(QEMU_SYSTEM_FILE)
	GDK_BACKEND=x11 qemu-system-x86_64 -cpu Broadwell -M q35 -serial stdio \
	-kernel "$(QEMU_KERNEL_FILE)" -initrd "$(QEMU_INITRD_FILE)" -append "$(QEMU_KERNEL_CMDLINE)" \
	-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
	-device virtio-vga-gl -display gtk,gl=on,zoom-to-fit=off \
	-nic user,model=virtio-net-pci,mac=52:54:00:12:34:56,hostfwd=tcp::5522-:22 \
	-m "$(QEMU_MEM)" -smp 4 $(QEMU_KVM) -device virtio-mouse-pci \
	-audiodev sdl,id=audio0 -device virtio-sound-pci,audiodev=audio0 \
	-drive file="$(QEMU_SYSTEM_FILE)",format=raw,if=virtio,id=system
.PHONY: qemu


# 文件夹创建目标自动生成
# 所有 *_DIR 变量、$(O) 都会被自动 mkdir -p
DIR_VARS := $(filter %_DIR,$(.VARIABLES))
ALL_DIRS := $(sort $(foreach v,$(DIR_VARS),$($(v))))
$(ALL_DIRS) $(O):
	mkdir -p $@

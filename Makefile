V ?= 0
ifeq ($(V),0)
.SILENT:
endif

O := $(shell pwd)
INITRD_DIR := $(O)/initrd
ROOTFS_DIR := $(O)/rootfs
KERNEL_DIR := $(O)/kernel
OVERLAY_DIR := $(O)/overlay
SHIM_GRUB_DIR := $(O)/shim_grub

INITRD_FILE := $(O)/initrd.cpio.gz
INITRD_PACKAGES += busybox

ROOTFS_FILE := $(O)/system.sfs
ROOTFS_PACKAGES += base linux-firmware-broadcom linux-firmware-intel libva-intel-driver intel-ucode vulkan-intel irqbalance zram-generator sudo
ROOTFS_PACKAGES += e2fsprogs exfatprogs dosfstools f2fs-tools btrfs-progs pciutils usbutils
ROOTFS_PACKAGES += mesa noto-fonts-cjk noto-fonts-emoji
ROOTFS_PACKAGES += pipewire-pulse pipewire-alsa alsa-utils bluez-utils mpv
ROOTFS_PACKAGES += networkmanager plasma-keyboard power-profiles-daemon
ROOTFS_PACKAGES += plasma-login-manager plasma-desktop plasma-pa plasma-nm plasma-systemmonitor breeze-gtk kde-gtk-config
ROOTFS_PACKAGES += powerdevil kscreen kgamma kinfocenter konsole fcitx5-im kcm-fcitx5 fcitx5-chinese-addons
ROOTFS_PACKAGES += kate dolphin colord-kde gpm ark kwalletmanager kdeconnect sshfs bluedevil iio-sensor-proxy plasma-wayland-protocols krdp

KERNEL_MODULES_FILE := $(O)/kernel_modules.cpio.gz
KERNEL_PACKAGE_FILE := $(wildcard kernel-*.tar.gz)
KERNEL_IMAGE_FILE := $(wildcard $(KERNEL_DIR)/vmlinuz*)
ifeq ($(KERNEL_IMAGE_FILE),)
KERNEL_IMAGE_FILE := $(KERNEL_DIR)/vmlinuz
endif

INITRD_KMOD_DIR := $(O)/initrd_kmod
INITRD_KMOD_FILE := $(O)/initrd_kmod.cpio.gz

RM := sudo rm -rf
CP := sudo cp -r
CHMOD := sudo chmod -R 755
CHOWN := sudo chown -R 0:0
MKDIR := sudo mkdir -p
LN := sudo ln -s

MAKE := sudo make
OVERLAY := $(MAKE) -C $(OVERLAY_DIR) V=$V
CHROOT := sudo arch-chroot
PACSTRAP := sudo pacstrap -C pacman.conf -c

SHIM_URL := https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/os/Packages/s/shim-x64-15.8-3.x86_64.rpm
GRUB2_EFI_URL := https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/os/Packages/g/grub2-efi-x64-2.12-40.fc43.x86_64.rpm

SHIM_FILE := $(O)/shim-x64.rpm
GRUB2_EFI_FILE := $(O)/grub2-efi-x64.rpm
$(SHIM_FILE): | $(O)
	wget --quiet "$(SHIM_URL)" -O "$@"
$(GRUB2_EFI_FILE): | $(O)
	wget --quiet "$(GRUB2_EFI_URL)" -O "$@"

SHIM_GRUB_STAMP := $(O)/.shim-grub_stamp
unpack_shim_grub $(SHIM_GRUB_STAMP): $(SHIM_FILE) $(GRUB2_EFI_FILE) | $(SHIM_GRUB_DIR)
	echo "解包shim文件"
	rpm2cpio $(SHIM_FILE) | cpio -idm -D "$(SHIM_GRUB_DIR)"
	rpm2cpio $(GRUB2_EFI_FILE) | cpio -idm -D "$(SHIM_GRUB_DIR)"
	touch $(SHIM_GRUB_STAMP)
	echo "解包shim文件:" "完成"
clean_shim_grub:
	$(RM) $(SHIM_GRUB_STAMP)
	$(RM) $(SHIM_GRUB_DIR)
.PHONY: unpack_shim_grub clean_shim_grub

INITRD_STRAP := $(O)/.initrd_strap
create_initrd $(INITRD_STRAP): | $(INITRD_DIR)
	$(MKDIR) "$(INITRD_DIR)/usr/sbin" "$(INITRD_DIR)/mnt" "$(INITRD_DIR)/sys_root"
	$(LN) /usr/bin "$(INITRD_DIR)/bin"
	$(LN) /usr/sbin "$(INITRD_DIR)/sbin"

	$(PACSTRAP) $(INITRD_DIR) $(INITRD_PACKAGES)

	$(CHROOT) $(INITRD_DIR) busybox --install -s
	$(CHROOT) $(INITRD_DIR) rm -rf /etc/pacman.d /usr/share/{man,doc} /var/cache /var/lib/pacman /var/log

	$(OVERLAY) O="$(INITRD_DIR)" initrd
	touch $(INITRD_STRAP)
initrd pack_initrd $(INITRD_FILE): $(INITRD_STRAP) | $(INITRD_DIR)
	cd $(INITRD_DIR) && find . | cpio -o -H newc | gzip > $(INITRD_FILE)
clean_initrd:
	$(RM) $(INITRD_STRAP)
	$(RM) $(INITRD_DIR)
	$(RM) $(INITRD_FILE)
initrd_shell: $(INITRD_STRAP) | $(INITRD_DIR)
	$(CHROOT) --unshare $(INITRD_DIR) ash
.PHONY: initrd initrd_shell clean_initrd

ROOTFS_STRAP := $(O)/.rootfs_strap
create_rootfs $(ROOTFS_STRAP): | $(ROOTFS_DIR)
	$(PACSTRAP) $(ROOTFS_DIR) $(ROOTFS_PACKAGES)

	$(CHROOT) $(ROOTFS_DIR) ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
	$(CHROOT) $(ROOTFS_DIR) locale-gen
	$(CHROOT) $(ROOTFS_DIR) useradd -m -G wheel,lp -s '/usr/bin/bash' user
	$(CHROOT) $(ROOTFS_DIR) balooctl6 disable
	echo "root:123456" | $(CHROOT) $(ROOTFS_DIR) chpasswd
	echo "user:123456" | $(CHROOT) $(ROOTFS_DIR) chpasswd
	$(CHROOT) $(ROOTFS_DIR) systemctl enable plasmalogin
	$(CHROOT) $(ROOTFS_DIR) systemctl enable NetworkManager
	$(CHROOT) $(ROOTFS_DIR) systemctl enable bluetooth
	$(CHROOT) $(ROOTFS_DIR) systemctl enable power-profiles-daemon
	$(CHROOT) $(ROOTFS_DIR) systemctl enable irqbalance
	$(CHROOT) $(ROOTFS_DIR) systemctl enable systemd-zram-setup@zram0.service
	$(CHROOT) $(ROOTFS_DIR) rm -rf /var/cache/pacman /var/lib/pacman /var/log

	$(OVERLAY) O="$(ROOTFS_DIR)" rootfs

	touch $(ROOTFS_STRAP)
rootfs pack_rootfs $(ROOTFS_FILE): $(ROOTFS_STRAP) | $(ROOTFS_DIR)
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
	tar -xf $(KERNEL_PACKAGE_FILE) -C $(KERNEL_DIR)
pack_kernel kernel $(KERNEL_MODULES_FILE): $(KERNEL_IMAGE_FILE) | $(KERNEL_DIR)
	$(RM) $(KERNEL_DIR)/usr
	cd $(KERNEL_DIR) && find . ! -name "vmlinuz*" | cpio -o -H newc | gzip > $(KERNEL_MODULES_FILE)
clean_kernel:
	$(RM) $(KERNEL_DIR)
.PHONY: unpack_kernel pack_kernel kernel clean_kernel

clean: clean_initrd clean_rootfs clean_kernel clean_shim_grub
dist_clean: clean
	$(RM) $(SHIM_FILE)
	$(RM) $(GRUB2_EFI_FILE)
.PHONY: clean dist_clean

INITRD_KMOD_STRAP := $(O)/.initrd_kmod_strap
initrd_with_kmod create_initrd_kmod $(INITRD_KMOD_STRAP): $(KERNEL_IMAGE_FILE) $(INITRD_STRAP)| $(INITRD_KMOD_DIR)
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

QEMU_DEBUG := 0
KERNEL_DEFAULT_CMDLINE := console=ttyS0,115200 console=tty1 DEBUG=$(QEMU_DEBUG) video=1280x720 panic=0
EXTRA_KERNEL_CMDLINE := ROOT_SEARCH_FILES=/sbin/init quiet
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
DIR_VARS := $(filter %_DIR,$(.VARIABLES)) $(O)
ALL_DIRS := $(foreach v,$(DIR_VARS),$($(v)))
$(ALL_DIRS):
	mkdir -p $@

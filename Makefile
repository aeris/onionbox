#DEBIAN_REPOSITORY := http://http.debian.net/debian/
DEBIAN_REPOSITORY := http://localhost:3142/http.debian.net/debian/
DEBIAN_RELEASE := jessie
SDCARD_DEV := /dev/sdd
MAKE_OPTIONS := -j8
RSYNC_EXCLUDES := --exclude build/
export CROSS_COMPILE := ccache arm-linux-gnueabihf-
export ARCH := arm
.DEFAULT_GOAL := flash

.PHONY: all build apt resources setup uboot kernel format flash_uboot debootstrap rootfs overlay flash_rootfs all_rootfs flash distclean rsync dersync tor_ipset overlay/etc/tor/ipset img flash_img

rsync:
	rsync -ahxP --delete . torbox-dev.local:torbox/ $(RSYNC_EXCLUDES)
dersync: rsync
	rsync -ahxP --delete torbox-dev.local:torbox/ .

all: rootfs

build: uboot kernel rootfs flash

apt:
	echo "deb http://emdebian.org/tools/debian/ jessie main" > /etc/apt/sources.list.d/embedian.list
	curl http://emdebian.org/tools/debian/emdebian-toolchain-archive.key | apt-key add -
	dpkg --add-architecture armhf
	apt update
	apt install crossbuild-essential-armhf ncurses-dev u-boot-tools build-essential git dosfstools aria2 wget qemu-user-static debootstrap binfmt-support rsync ccache apt-cacher-ng parted -y

resources:
	[ -d resources ] || mkdir resources
	$(eval GITHUB := https://github.com/OLIMEX/OLINUXINO/raw/master/SOFTWARE/A20/A20-build-3.4.90)
	wget -q --show-progress $(GITHUB)/script_a20_lime_3.4.90_camera_rel_3/script.bin -O resources/script.bin
	wget -q --show-progress $(GITHUB)/spi-sun7i.c -O resources/spi-sun7i.c
	wget -q --show-progress $(GITHUB)/SPI.patch -O resources/SPI.patch
	wget -q --show-progress $(GITHUB)/a20_olimex_defconfig -O resources/a20_olimex_defconfig
	sed -i "s/.*CONFIG_FHANDLE.*/CONFIG_FHANDLE=y/" resources/a20_olimex_defconfig

setup: apt resources
	[ -d sd ] || mkdir sd

build/u-boot/:
	git clone https://github.com/linux-sunxi/u-boot-sunxi.git -b sunxi --depth 1 $@
	# Current rev : fec9bf7003b79f836ff104e92755317149b259b6

build/u-boot/include/config.mk: | build/u-boot/
	$(MAKE) -C build/u-boot A20-OLinuXino-Lime_config

build/u-boot/u-boot-sunxi-with-spl.bin: build/u-boot/include/config.mk
	$(MAKE) -C build/u-boot $(MAKE_OPTIONS)

uboot: build/u-boot/u-boot-sunxi-with-spl.bin

build/linux/:
	git clone https://github.com/linux-sunxi/linux-sunxi.git -b sunxi-3.4 --depth 1 $@
	# Current rev : d47d367036be38c5180632ec8a3ad169a4593a88
	cp resources/spi-sun7i.c build/linux/drivers/spi/spi-sun7i.c
	patch -p0 -d build/linux < resources/SPI.patch

build/linux/arch/arm/configs/a20_olimex_defconfig: resources/a20_olimex_defconfig | build/linux/
	cp $< $@

#build/linux/.config: build/linux/arch/arm/configs/a20_olimex_defconfig
#	$(MAKE) -C build/linux a20_olimex_defconfig
build/linux/.config: resources/config
	cp $< $@

build/linux/arch/arm/boot/uImage: build/linux/.config
	$(MAKE) -C build/linux $(MAKE_OPTIONS) uImage
	INSTALL_MOD_PATH=out $(MAKE) -C build/linux $(MAKE_OPTIONS) modules
	INSTALL_MOD_PATH=out $(MAKE) -C build/linux $(MAKE_OPTIONS) modules_install

kernel: build/linux/arch/arm/boot/uImage

format:
	# First partition : 16MB, VFAT
	# Second partition : remaining space, EXT-4
	/sbin/parted -a optimal --script $(SDCARD_DEV) \
		mklabel msdos \
		mkpart primary fat32 2048s 34815s \
		mkpart primary ext4 34816s 100% \
		print
	mkfs.vfat $(SDCARD_DEV)1
	mkfs.ext4 $(SDCARD_DEV)2

flash_uboot: build/u-boot/u-boot-sunxi-with-spl.bin build/linux/arch/arm/boot/uImage
	dd if=$(word 1,$^) of=$(SDCARD_DEV) bs=1024 seek=8
	sleep 2
	mount $(SDCARD_DEV)1 build/sd
	cp $(word 2,$^) build/sd/uImage
	cp resources/script.bin build/sd/script.bin
	umount build/sd

build/rootfs/: configure
	$(eval PACKAGES := $(shell egrep -v '^(#|$$)' packages | tr "\n" ,))
	qemu-debootstrap --arch=armhf --variant=minbase --include=$(PACKAGES) $(DEBIAN_RELEASE) $@ $(DEBIAN_REPOSITORY)
	rm -f $@/etc/ssh/ssh_host_*_key*

	[ -x $@/usr/bin/qemu-arm-static ] || cp /usr/bin/qemu-arm-static $@/usr/bin/qemu-arm-static
	$(MAKE) overlay
	chroot $@ /bin/bash < configure
	$(MAKE) overlay
	date -u '+%Y-%m-%d %H:%M:%S' > $@/etc/etc/fake-hwclock.data
	rm -f $@/usr/bin/qemu-arm-static

rootfs: | build/rootfs/

chroot:
	[ -x build/rootfs/usr/bin/qemu-arm-static ] || cp /usr/bin/qemu-arm-static build/rootfs/usr/bin/qemu-arm-static
	sed -i s/tor+// build/rootfs/etc/apt/sources.list.d/*.list
	echo 'Acquire::http { Proxy "http://localhost:3142"; };' > build/rootfs/etc/apt/apt.conf.d/00proxy

	-chroot build/rootfs /bin/bash

	rm build/rootfs/etc/apt/apt.conf.d/00proxy
	sed -i s/http:/tor+http:/ build/rootfs/etc/apt/sources.list.d/*.list
	rm build/rootfs/usr/bin/qemu-arm-static
	rm -rf build/rootfs/var/cache/apt/archives/*
	find build/rootfs/var/log -type f -delete

overlay/etc/tor/ipset:
	overlay/usr/local/bin/update-tor-ipset -i ~/.tor/cached-microdesc-consensus -o $@
tor_ipset: overlay/etc/tor/ipset

overlay: | build/rootfs/
	rsync -ahxP --chown=root:root --delete build/linux/out/lib/modules/ build/rootfs/lib/modules/
	rsync -ahxP --chown=root:root --delete build/linux/out/lib/firmware/ build/rootfs/lib/firmware/
	rsync -ahxP --usermap=1000:root --groupmap=1000:root overlay/ build/rootfs/

rsync_overlay:
	#rsync -ahxP --chown=root:root --delete build/linux/out/lib/modules/ torbox.local:/lib/modules/
	#rsync -ahxP --chown=root:root --delete build/linux/out/lib/firmware/ torbox.local:/lib/firmware/
	rsync -ahxP --usermap=1000:root --groupmap=1000:root overlay/ torbox.local:/

flash_rootfs: overlay
	mount $(SDCARD_DEV)2 build/sd
	rsync -ahxAHPX --numeric-ids --delete build/rootfs/ build/sd/
	umount build/sd

all_rootfs: rootfs flash_rootfs

flash: flash_uboot flash_rootfs

build/torbox.img: build/u-boot/u-boot-sunxi-with-spl.bin build/linux/arch/arm/boot/uImage overlay
	truncate -s 1G $@

	$(eval DEVICE := $(shell losetup -f))
	losetup $(DEVICE) $@
	/sbin/parted -a optimal --script $(DEVICE) \
		mklabel msdos \
		mkpart primary fat32 2048s 16MB \
		mkpart primary ext4 16MB 100% \
		print
	mkfs.vfat $(DEVICE)p1
	mkfs.ext4 $(DEVICE)p2

	dd if=$(word 1,$^) of=$(DEVICE) bs=1K seek=8
	sleep 2
	mount $(DEVICE)p1 build/sd
	cp $(word 2,$^) build/sd/uImage
	cp resources/script.bin build/sd/script.bin
	umount build/sd

	mount $(DEVICE)p2 build/sd
	rsync -ahxAHPX --numeric-ids --delete build/rootfs/ build/sd/
	umount build/sd

	sync
	sleep 2
	losetup -d $(DEVICE)

img: build/torbox.img
flash_img:
	pv build/torbox.img | dd of=$(SDCARD_DEV) bs=1M

distclean:
	$(MAKE) -C build/u-boot distclean
	$(MAKE) -C build/linux distclean

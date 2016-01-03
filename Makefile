DEBIAN_REPOSITORY := http://localhost:3142/http.debian.net/debian/
DEBIAN_RELEASE := jessie
GITHUB_OLIMEX := https://github.com/OLIMEX/OLINUXINO/raw/master/SOFTWARE/A20/A20-build-3.4.90
GITHUB_SUNXI := https://github.com/linux-sunxi
SDCARD_DEV := /dev/sdd
MAKE_OPTIONS := -j8
IMG_SIZE := 4G
.DEFAULT_GOAL := img
MAKEFLAGS += --no-builtin-rules
export CROSS_COMPILE := ccache arm-linux-gnueabihf-
export ARCH := arm

.PHONY: build chroot clean desync dev distclean firmwares flash format img img_compress img_flash linux modules mr-proper overlay overlay_sync resources rootfs rootfs_flash rootfs_sync sync tor_ipset tor_keyring uboot uboot_flash

sync:
	rsync -ahxP --delete . torbox-dev.local:torbox/ --exclude-from .exclude
desync: sync
	rsync -ahxP --delete torbox-dev.local:torbox/ .

resources/u-boot/:
	# Current rev : fec9bf7003b79f836ff104e92755317149b259b6
	git clone $(GITHUB_SUNXI)/u-boot-sunxi.git --bare -b sunxi --depth 1 $@
resources/linux/:
	# Current rev : d47d367036be38c5180632ec8a3ad169a4593a88
	git clone $(GITHUB_SUNXI)/linux-sunxi.git --bare -b sunxi-3.4 --depth 1 $@
resources/script.bin:
	wget -q --show-progress $(GITHUB_OLIMEX)/script_a20_lime_3.4.90_camera_rel_3/script.bin -O $@
resources/spi-sun7i.c:
	wget -q --show-progress $(GITHUB_OLIMEX)/spi-sun7i.c -O $@
resources/SPI.patch:
	wget -q --show-progress $(GITHUB_OLIMEX)/SPI.patch -O $@
resources/a20_olimex_defconfig:
	wget -q --show-progress $(GITHUB_OLIMEX)/a20_olimex_defconfig -O $@
	sed -i "s/.*CONFIG_FHANDLE.*/CONFIG_FHANDLE=y/" $@

resources: resources/u-boot/ resources/linux/ resources/script.bin resources/spi-sun7i.c \
	resources/SPI.patch resources/a20_olimex_defconfig

dev:
	echo "deb http://emdebian.org/tools/debian/ jessie main" > /etc/apt/sources.list.d/embedian.list
	curl http://emdebian.org/tools/debian/emdebian-toolchain-archive.key | apt-key add -
	dpkg --add-architecture armhf
	apt update
	apt install crossbuild-essential-armhf ncurses-dev u-boot-tools build-essential git dosfstools aria2 wget qemu-user-static debootstrap binfmt-support rsync ccache apt-cacher-ng parted secure-delete tor python-stem -y
	gpg2 --recv-key 0xEE8CBC9E886DDD89

overlay/etc/apt/trusted.gpg.d/ overlay/etc/tor/ overlay/etc/default/ overlay/usr/local/bin/ build/sd/:
	mkdir -p $@

build/u-boot/: | resources/u-boot/
	git clone resources/u-boot/ -b sunxi --depth 1 $@
build/u-boot/include/config.mk: | build/u-boot/
	$(MAKE) -C build/u-boot A20-OLinuXino-Lime_config
build/u-boot/u-boot-sunxi-with-spl.bin: build/u-boot/include/config.mk
	$(MAKE) -C build/u-boot $(MAKE_OPTIONS)
uboot: build/u-boot/u-boot-sunxi-with-spl.bin
uboot_flash: resources/script.bin build/linux/arch/arm/boot/uImage build/u-boot/u-boot-sunxi-with-spl.bin | build/sd/
	mount $(SDCARD_DEV)1 build/sd
	cp $(word 1,$^) build/sd/script.bin
	cp $(word 2,$^) build/sd/uImage
	umount build/sd
	dd if=$(word 3,$^) of=$(SDCARD_DEV) bs=1K seek=8

build/linux/: resources/spi-sun7i.c resources/SPI.patch | resources/linux/
	git clone resources/linux -b sunxi-3.4 --depth 1 $@
	cp resources/spi-sun7i.c build/linux/drivers/spi/spi-sun7i.c
	patch -p0 -d build/linux < resources/SPI.patch
build/linux/arch/arm/configs/a20_olimex_defconfig: resources/a20_olimex_defconfig | build/linux/
	cp $< $@
build/linux/.config: resources/config | build/linux/
	cp $< $@
build/linux/arch/arm/boot/uImage: build/linux/.config
	$(MAKE) -C build/linux $(MAKE_OPTIONS) uImage
	INSTALL_MOD_PATH=out $(MAKE) -C build/linux $(MAKE_OPTIONS) modules
	INSTALL_MOD_PATH=out $(MAKE) -C build/linux $(MAKE_OPTIONS) modules_install
linux: build/linux/arch/arm/boot/uImage

overlay/etc/tor/ipset:  | overlay/etc/tor/
	overlay/usr/local/bin/update-tor-ipset -o $@
tor_ipset: overlay/etc/tor/ipset
overlay/etc/apt/trusted.gpg.d/deb.torproject.org.gpg tor_keyring: | overlay/etc/apt/trusted.gpg.d/
	gpg2 --export --export-options export-minimal --no-armor 0xEE8CBC9E886DDD89 > $@
tor_keyring: overlay/etc/apt/trusted.gpg.d/deb.torproject.org.gpg
overlay: overlay/etc/tor/ipset overlay/etc/apt/trusted.gpg.d/deb.torproject.org.gpg
	rsync -ahxP --usermap=1000:root --groupmap=1000:root $@/* build/rootfs/
overlay_sync: | overlay
	rsync -ahxP --usermap=1000:root --groupmap=1000:root overlay/ torbox.local:/

build/rootfs/: configure packages resources/rsyslog.patch
	$(eval PACKAGES := $(shell egrep -v '^(#|$$)' packages | tr "\n" ,))
	rm -rf $@
	qemu-debootstrap --arch=armhf --variant=minbase --include=$(PACKAGES) $(DEBIAN_RELEASE) $@ $(DEBIAN_REPOSITORY)
	# Fix a bug with xconsole filling syslog
	patch -p0 -d $@ < resources/rsyslog.patch
	rm -f $@/etc/ssh/ssh_host_*_key*

	[ -x $@/usr/bin/qemu-arm-static ] || cp /usr/bin/qemu-arm-static $@/usr/bin/qemu-arm-static
	$(MAKE) overlay
	for i in proc dev sys; do mount -o bind /$$i $@/$$i; done
	chroot $@ /bin/bash < configure
	for i in proc dev sys; do umount $@/$$i; done
	$(MAKE) overlay modules
	date -u '+%Y-%m-%d %H:%M:%S' > $@/etc/fake-hwclock.data
	rm -f $@/usr/bin/qemu-arm-static
build/rootfs/lib/modules/: linux
	rsync -ahxP --chown=root:root --delete build/linux/out/lib/modules/ $@
modules: | build/rootfs/lib/modules/
build/rootfs/lib/firmware/: linux
	rsync -ahxP --chown=root:root --delete build/linux/out/lib/firmware/ $@
firmwares: | build/rootfs/lib/firmware/
rootfs: | build/rootfs/ modules overlay
rootfs_flash: | rootfs build/sd/
	mount $(SDCARD_DEV)2 build/sd
	rsync -ahxAHPX --numeric-ids --delete build/rootfs/ build/sd/
	umount build/sd
rootfs_sync: | rootfs
	rsync -ahxP --numeric-ids --delete build/rootfs/ torbox.local:/

flash: uboot_flash rootfs_flash

build/torbox.img: resources/script.bin uboot linux | rootfs build/sd/
	truncate -s $(IMG_SIZE) $@

	$(eval DEVICE := $(shell losetup -f))
	losetup $(DEVICE) $@
	/sbin/parted -a optimal --script $(DEVICE) \
		mklabel msdos \
		mkpart primary fat32 2048s 34815s \
		mkpart primary ext4 34816s 100% \
		print
	mkfs.vfat $(DEVICE)p1
	mkfs.ext4 $(DEVICE)p2

	mount $(DEVICE)p1 build/sd
	cp build/linux/arch/arm/boot/uImage build/sd/uImage
	cp resources/script.bin build/sd/script.bin
	sfill -ziIllf build/sd
	umount build/sd

	mount $(DEVICE)p2 build/sd
	rsync -ahxAHPX --numeric-ids --delete build/rootfs/ build/sd/
	sfill -zllf build/sd
	umount build/sd

	dd if=build/u-boot/u-boot-sunxi-with-spl.bin of=$(DEVICE) bs=1K seek=8

	losetup -d $(DEVICE)
img: build/torbox.img
build/torbox.img.xz: build/torbox.img
	pxz -k $<
img_compress: build/torbox.img.xz
img_flash: build/torbox.img
	pv $< | dd of=$(SDCARD_DEV) bs=1M

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
chroot:
	[ -x build/rootfs/usr/bin/qemu-arm-static ] || cp /usr/bin/qemu-arm-static build/rootfs/usr/bin/qemu-arm-static
	sed -i s/tor+// build/rootfs/etc/apt/sources.list.d/*.list
	echo 'Acquire::http { Proxy "http://localhost:3142"; }' > build/rootfs/etc/apt/apt.conf.d/00proxy

	-chroot build/rootfs /bin/bash

	rm build/rootfs/etc/apt/apt.conf.d/00proxy
	sed -i s/http:/tor+http:/ build/rootfs/etc/apt/sources.list.d/*.list
	rm build/rootfs/usr/bin/qemu-arm-static
	rm -rf build/rootfs/var/cache/apt/archives/*
	find build/rootfs/var/log -type f -delete

clean:
	rm -rf build/rootfs build/torbox.img build/torbox.img.xz overlay/etc/apt/trusted.gpg.d/deb.torproject.org.gpg
distclean:
	$(MAKE) -C build/u-boot distclean
	$(MAKE) -C build/linux distclean
mr-proper: clean
	rm -rf build/* resources/u-boot/ resources/linux/ resources/a20_olimex_defconfig resources/script.bin resources/SPI.patch resources/spi-sun7i.c

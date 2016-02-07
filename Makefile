DEBIAN_REPOSITORY := http://localhost:3142/http.debian.net/debian/
DEBIAN_RELEASE := jessie
SDCARD_DEV := /dev/sdd
MAKE_OPTIONS := -j8
IMG_SIZE := 4G
.DEFAULT_GOAL := img
MAKEFLAGS += --no-builtin-rules

UBOOT_DEBIAN_VERSION := 2014.10+dfsg1-5
LINUX_GIT_VERSION := 4.4.1
LINUX_VERSION := $(LINUX_GIT_VERSION)+

export CROSS_COMPILE := ccache arm-linux-gnueabihf-
export ARCH := arm

.PHONY: build chroot clean desync dev distclean flash format img img_compress img_flash linux linux_flash mr-proper overlay overlay_sync resources rootfs rootfs_flash rootfs_sync sync tor_ipset tor_keyring uboot uboot_flash

sync:
	rsync -ahxP --delete . torbox-dev.local:torbox/ --exclude-from .exclude
desync: sync
	rsync -ahxP --delete torbox-dev.local:torbox/ .

dev:
	echo "deb http://emdebian.org/tools/debian/ jessie main" > /etc/apt/sources.list.d/embedian.list
	curl http://emdebian.org/tools/debian/emdebian-toolchain-archive.key | apt-key add -
	dpkg --add-architecture armhf
	apt update
	apt install build-essential crossbuild-essential-armhf ncurses-dev u-boot-tools device-tree-compiler build-essential git dosfstools aria2 wget qemu-user-static debootstrap binfmt-support rsync ccache apt-cacher-ng parted secure-delete pv tor python-stem -y
	gpg2 --recv-key 0xEE8CBC9E886DDD89

overlay/etc/apt/trusted.gpg.d/ overlay/etc/tor/ overlay/etc/default/ overlay/usr/local/bin/ build/sd/:
	mkdir -p $@

build/u-boot-sunxi_$(UBOOT_DEBIAN_VERSION)_armhf.deb:
	cd build && apt-get download u-boot-sunxi=$(UBOOT_DEBIAN_VERSION)
build/u-boot/usr/lib/u-boot/A20-OLinuXino-Lime/u-boot-sunxi-with-spl.bin: build/u-boot-sunxi_$(UBOOT_DEBIAN_VERSION)_armhf.deb
	dpkg -x $< build/u-boot
uboot: build/u-boot/usr/lib/u-boot/A20-OLinuXino-Lime/u-boot-sunxi-with-spl.bin
uboot_flash: build/u-boot/usr/lib/u-boot/A20-OLinuXino-Lime/u-boot-sunxi-with-spl.bin
	pv $< | dd of=$(SDCARD_DEV) bs=1K seek=8
	sync

resources/linux/:
	git clone --bare --depth 1 -b v$(LINUX_GIT_VERSION) git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git $@
build/linux/: | resources/linux/
	git clone resources/linux/ $@ -b v$(LINUX_GIT_VERSION)
	patch -p1 -d $@ < resources/usb0.patch
build/linux/.config: resources/config | build/linux/
	#$(MAKE) $(MAKE_OPTIONS) -C build/linux sunxi_defconfig
	cp $< $@
build/linux/arch/arm/boot/zImage build/linux/System.map: build/linux/.config
	$(MAKE) $(MAKE_OPTIONS) -C build/linux zImage modules
	rm -rf build/linux/output
	INSTALL_MOD_PATH=output LOCALVERSION= $(MAKE) $(MAKE_OPTIONS) -C build/linux modules_install
build/linux/arch/arm/boot/dts/sun7i-a20-olinuxino-lime.dtb: build/linux/.config
	$(MAKE) $(MAKE_OPTIONS) -C build/linux dtbs
linux: build/linux/arch/arm/boot/zImage build/linux/System.map build/linux/arch/arm/boot/dts/sun7i-a20-olinuxino-lime.dtb
linux_flash: linux
	mount $(SDCARD_DEV)1 build/sd
	cp build/linux/arch/arm/boot/zImage build/sd/boot/vmlinuz-$(LINUX_VERSION)
	cp build/linux/System.map build/sd/boot/System.map-$(LINUX_VERSION)
	cp build/linux/arch/arm/boot/dts/sun7i-a20-olinuxino-lime.dtb build/sd/boot/dtb-$(LINUX_VERSION)
	cp build/linux/.config build/sd/boot/config-$(LINUX_VERSION)
	rsync -ahxP --delete build/linux/output/lib/modules/$(LINUX_VERSION)/ build/sd/lib/modules/$(LINUX_VERSION)
	[ -d build/linux/output/lib/firmware ] && rsync -ahxP --delete build/linux/output/lib/firmware build/sd/lib/ || true
	[ -x build/sd/usr/bin/qemu-arm-static ] || cp /usr/bin/qemu-arm-static build/sd/usr/bin/qemu-arm-static
	chroot build/sd update-initramfs -utk $(LINUX_VERSION)
	rm -f build/sd/usr/bin/qemu-arm-static
	umount build/sd
xconfig:
	$(MAKE) -C build/linux xconfig

overlay/etc/tor/ipset: overlay/usr/local/bin/update-tor-ipset
	$< -o $@
tor_ipset: overlay/etc/tor/ipset
overlay/etc/apt/trusted.gpg.d/deb.torproject.org.gpg tor_keyring: | overlay/etc/apt/trusted.gpg.d/
	gpg2 --export --export-options export-minimal --no-armor 0xEE8CBC9E886DDD89 > $@
tor_keyring: overlay/etc/apt/trusted.gpg.d/deb.torproject.org.gpg
overlay/usr/local/bin/htpdate: | overlay/usr/local/bin/
	wget -q --show-progress https://git-tails.immerda.ch/tails/plain/config/chroot_local-includes/usr/local/sbin/htpdate -O $@
	chmod u+x $@
overlay/etc/default/htpdate.pools: | overlay/etc/default/
	wget -q --show-progress https://git-tails.immerda.ch/tails/tree/config/chroot_local-includes/etc/default/htpdate.pools -O $@
overlay: overlay/etc/tor/ipset overlay/etc/apt/trusted.gpg.d/deb.torproject.org.gpg overlay/usr/local/bin/htpdate overlay/etc/default/htpdate.pools | build/rootfs/
	rsync -ahxP --usermap=1000:root --groupmap=1000:root $@/* build/rootfs/
overlay_sync: overlay
	rsync -ahxP --usermap=1000:root --groupmap=1000:root overlay/ torbox:/

build/rootfs/: packages configure configure.packages resources/rsyslog.patch
	$(eval PACKAGES := $(shell egrep -v '^(#|//|$$)' packages | tr "\n" ,))
	rm -rf $@
	qemu-debootstrap --arch=armhf --variant=minbase --components=main,contrib,non-free --include=$(PACKAGES) $(DEBIAN_RELEASE) $@ $(DEBIAN_REPOSITORY)

	$(MAKE) overlay
	for i in proc dev dev/pts sys; do mount -o bind /$$i $@/$$i; done
	cp configure.packages $@/tmp/packages
	[ -x $@/usr/bin/qemu-arm-static ] || cp /usr/bin/qemu-arm-static $@/usr/bin/qemu-arm-static
	chroot $@ /bin/bash < configure
	rm -f $@/usr/bin/qemu-arm-static
	rm -f $@/tmp/packages
	for i in proc dev/pts dev sys; do umount $@/$$i; done
	# Fix a bug with xconsole filling syslog
	patch -p0 -d $@ < resources/rsyslog.patch
	rm -f $@/etc/ssh/ssh_host_*_key*
	$(MAKE) overlay
	date -u '+%Y-%m-%d %H:%M:%S' > $@/etc/fake-hwclock.data

build/rootfs/boot/vmlinuz-$(LINUX_VERSION): build/linux/arch/arm/boot/zImage | build/rootfs/
	cp $< $@
	mkdir -p build/rootfs/lib/modules/
	rsync -ahxP --delete build/linux/output/lib/modules/$(LINUX_VERSION)/ build/rootfs/lib/modules/$(LINUX_VERSION)/
	[ -d build/linux/output/lib/firmware ] && rsync -ahxP --delete build/linux/output/lib/firmware build/rootfs/lib/ || true
build/rootfs/boot/initrd.img-$(LINUX_VERSION): build/rootfs/boot/vmlinuz-$(LINUX_VERSION) build/rootfs/boot/System.map-$(LINUX_VERSION) build/rootfs/boot/config-$(LINUX_VERSION)
	[ -x build/rootfs/usr/bin/qemu-arm-static ] || cp /usr/bin/qemu-arm-static build/rootfs/usr/bin/qemu-arm-static
	chroot build/rootfs update-initramfs -utk $(LINUX_VERSION)
	rm -f build/rootfs/usr/bin/qemu-arm-static

build/rootfs/boot/boot.scr: resources/boot.cmd | build/rootfs/
	mkimage -A arm -O linux -T script -C none -d $< $@
scr: build/rootfs/boot/boot.scr
build/rootfs/boot/dtb-$(LINUX_VERSION): build/linux/arch/arm/boot/dts/sun7i-a20-olinuxino-lime.dtb | build/rootfs/
	cp $< $@
build/rootfs/boot/System.map-$(LINUX_VERSION): build/linux/System.map | build/rootfs/
	cp $< $@
build/rootfs/boot/config-$(LINUX_VERSION): build/linux/.config | build/rootfs/
	cp $< $@

build/rootfs/boot/dtb: build/rootfs/boot/dtb-$(LINUX_VERSION)
	ln -fs $(notdir $<) $@
build/rootfs/boot/vmlinuz: build/rootfs/boot/vmlinuz-$(LINUX_VERSION)
	ln -fs $(notdir $<) $@
build/rootfs/boot/initrd.img: build/rootfs/boot/initrd.img-$(LINUX_VERSION)
	ln -fs $(notdir $<) $@
build/rootfs/boot/System.map: build/rootfs/boot/System.map-$(LINUX_VERSION)
	ln -fs $(notdir $<) $@
build/rootfs/boot/config: build/rootfs/boot/config-$(LINUX_VERSION)
	ln -fs $(notdir $<) $@
dtb: build/rootfs/boot/dtb
vmlinuz: build/rootfs/boot/vmlinuz
initrd: build/rootfs/boot/initrd.img
system.map: build/rootfs/boot/System.map
config: build/rootfs/boot/config
rootfs: overlay scr dtb vmlinuz initrd system.map config
rootfs_flash: rootfs | build/sd/
	mount $(SDCARD_DEV)1 build/sd
	rsync -ahxAHPX --numeric-ids --delete build/rootfs/ build/sd/
	umount build/sd
rootfs_sync: | rootfs
	rsync -ahxP --numeric-ids --delete --exclude dev --exclude sys --exclude proc build/rootfs/ torbox:/

flash: uboot_flash rootfs_flash

build/torbox.img: build/u-boot/usr/lib/u-boot/A20-OLinuXino-Lime/u-boot-sunxi-with-spl.bin | rootfs build/sd/
	truncate -s $(IMG_SIZE) $@

	$(eval DEVICE := $(shell losetup -f))
	losetup $(DEVICE) $@
	/sbin/parted -a optimal --script $(DEVICE) \
		mklabel msdos \
		mkpart primary ext4 2048s 100% \
		align-check optimal 1 \
		print
	sync
	mkfs.ext4 $(DEVICE)p1
	sync
	tune2fs -o journal_data_writeback $(DEVICE)p1

	mount $(DEVICE)p1 build/sd
	rsync -ahxAHPX --numeric-ids --delete build/rootfs/ build/sd/
	sfill -zllf build/sd
	umount build/sd

	pv build/u-boot/usr/lib/u-boot/A20-OLinuXino-Lime/u-boot-sunxi-with-spl.bin | dd of=$(DEVICE) bs=1K seek=8
	sync

	losetup -d $(DEVICE)
img: build/torbox.img
img_flash: build/torbox.img
	pv $< | dd of=$(SDCARD_DEV) bs=1M
	sync
build/torbox.img.xz: build/torbox.img
	pxz -k $<
img_compress: build/torbox.img.xz

format:
	/sbin/parted -a optimal --script $(SDCARD_DEV) \
		mklabel msdos \
		mkpart primary ext4 2048s 100% \
		align-check optimal 1 \
		print
	sync
	mkfs.ext4 $(SDCARD_DEV)1
	sync
	tune2fs -o journal_data_writeback $(SDCARD_DEV)1
chroot: | build/rootfs/
	for i in proc dev dev/pts sys; do mount -o bind /$$i build/rootfs/$$i; done

	[ -x build/rootfs/usr/bin/qemu-arm-static ] || cp /usr/bin/qemu-arm-static build/rootfs/usr/bin/qemu-arm-static
	sed -i s/tor+// build/rootfs/etc/apt/sources.list.d/*.list
	echo 'Acquire::http { Proxy "http://localhost:3142"; }' > build/rootfs/etc/apt/apt.conf.d/00proxy

	-chroot build/rootfs /bin/bash

	rm -f build/rootfs/etc/apt/apt.conf.d/00proxy
	sed -i s/http:/tor+http:/ build/rootfs/etc/apt/sources.list.d/*.list
	rm -f build/rootfs/usr/bin/qemu-arm-static
	rm -rf build/rootfs/var/cache/apt/archives/*
	find build/rootfs/var/log -type f -delete
	for i in proc dev/pts dev sys; do umount build/rootfs/$$i; done

clean:
	rm -rf build/rootfs/ build/torbox.img build/torbox.img.xz \ overlay/etc/apt/trusted.gpg.d/deb.torproject.org.gpg \
	overlay/etc/default/htpdate.pools overlay/usr/local/bin/htpdate
mr-proper: clean
	rm -rf build/*

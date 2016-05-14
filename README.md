# Tor Box

Tor Box project aims to build a Tor hardware router base on a [Olimex A20 OLinuXino LIME](https://www.olimex.com/Products/OLinuXino/A20/A20-OLinuXino-LIME/open-source-hardware) board.

One leitmotiv : torify them all.

# Design

# Build

The build process is currently tested on a fresh [Debian Jessie net install](http://cdimage.debian.org/debian-cd/8.4.0/amd64/bt-cd/debian-8.4.0-amd64-netinst.iso.torrent).
You need at least 4GB of RAM for the development machine (xz image compression require a lot of RAM).

Since the build process heavily modify the system (change APT repositories, install arm as foreign architecture…), it's better to use [VirtualBox](https://www.virtualbox.org/) to create a virtual machine.

Full automated installation preseed file [available](preseed.cfg).
The created machine use [Avahi](http://www.avahi.org/) and so can be joined with SSH on `torbox-dev.local`.
Root password is `root`.

To setup development system, just copy this folder into dev target (with `rsync` for example), then run `make dev` on the created folder.

To build the LIME image (`build/torbox.img`, 4GB), run `make img`, or `make img_compress` for the XZ compressed version (`build/torbox.img.xz`, ~100MB).

# Deployment

You need a 4GB or more SD card.
The provided Makefile assume you have your SD card available under `/dev/sdd`. [Modify it](Makefile#l3) if not.

You can flash your SD card with `dd if=torbox.img of=/dev/sdd` (or with `make img_flash` if on the dev machine).
If you want to use the compressed image without uncompressed it on disk, use `unxz -c torbox.img.xz | dd of=/dev/sdd`.

For development, because flashing 4GB on a SD card is slow and tedious, you can format your SD card with `make format` and then sync it content with `make flash` after a new build (or even `make rootfs_sync` if the Torbox is joinable from the development machine, avoiding the SD card switch).

# Usage

Use the LIME with UART serial port to debug the boot process (`/dev/ttyUSB0`, 1152000 bauds, 8 data bits, 1 stop bit, no sw/hw handshake).

You can connect to the mini-USB port, providing DHCP connectivity. Torbox is available with SSH on `10.0.0.1`.

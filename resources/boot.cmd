# boot script for Allwinner SunXi-based devices

# Mainline u-boot v2014.10 introduces a new default environment and
# a new common bootcmd handling for all platforms, which is not fully
# compatible with the old-style environment used by u-boot-sunxi.
# This script therefore needs to check in which environment it
# is running and set some variables accordingly.

# On u-boot-sunxi, this script assumes that ${device} and ${partition}
# are set.

# The new-style environment predefines ${boot_targets}, the old-style
# environment does not.
if test -n "${boot_targets}"
then
  echo "Mainline u-boot / new-style environment detected."
  # Mainline u-boot v2014.10 uses ${devtype}, ${devnum} and
  # ${bootpart} where u-boot-sunxi uses ${device} and ${partition}.
  if test -z "${device}"; then setenv device "${devtype}"; fi
  if test -z "${partition}"; then setenv partition "${devnum}:${bootpart}"; fi
else
  echo "U-boot-sunxi / old-style environment detected."
  # U-boot-sunxi does not predefine kernel_addr_r, fdt_addr_r and
  # ramdisk_addr_r, so they have to be manually set. Use the values
  # from mainline u-boot v2014.10, except for ramdisk_addr_r,
  # which is set to 0x44300000 to allow for initrds larger than
  # 13MB on u-boot-sunxi.
  setenv kernel_addr_r 0x42000000
  setenv fdt_addr_r 0x43000000
  setenv ramdisk_addr_r 0x44300000
fi

#if test -n "${console}"; then
#  setenv bootargs "${bootargs} console=${console}"
#fi

#setenv bootargs ${bootargs} console=ttyS0,115200n8 console=tty0 hdmi.audio=EDID:0 disp.screen0_output_mode=EDID:1280x720p60 root=/dev/mmcblk0p1 rootwait sunxi_ve_mem_reserve=0 sunxi_g2d_mem_reserve=0 sunxi_no_mali_mem_reserve sunxi_fb_mem_reserve=0 panic=10 loglevel=6 consoleblank=0
setenv bootargs console=ttyS0,115200n8 root=/dev/mmcblk0p1 rootwait sunxi_ve_mem_reserve=0 sunxi_g2d_mem_reserve=0 sunxi_no_mali_mem_reserve sunxi_fb_mem_reserve=0 panic=10 loglevel=6 consoleblank=0

image_locations='/boot/'

for pathprefix in ${image_locations}
do
  if test -e ${device} ${partition} ${pathprefix}vmlinuz
  then
    load ${device} ${partition} ${kernel_addr_r} ${pathprefix}vmlinuz \
    && load ${device} ${partition} ${fdt_addr_r} ${pathprefix}dtb \
    && load ${device} ${partition} ${ramdisk_addr_r} ${pathprefix}initrd.img \
    && echo "Booting Debian ${kvers} from ${device} ${partition}..." \
    && bootz ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
  fi
done

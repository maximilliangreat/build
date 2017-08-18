# Copyright (c) 2015 Igor Pecovnik, igor.pecovnik@gma**.com
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.

# This file is a part of the Armbian build script
# https://github.com/armbian/build/

# Create board support packages
#
# Functions:
# create_board_package

create_board_package()
{
	display_alert "Creating board support package" "$BOARD $BRANCH" "info"

	local destination=$SRC/.tmp/${RELEASE}/${CHOSEN_ROOTFS}_${REVISION}_${ARCH}
	rm -rf $destination
	mkdir -p $destination/DEBIAN

	# Replaces: base-files is needed to replace /etc/update-motd.d/ files on Xenial
	# Replaces: unattended-upgrades may be needed to replace /etc/apt/apt.conf.d/50unattended-upgrades
	# (distributions provide good defaults, so this is not needed currently)
	# Depends: linux-base is needed for "linux-version" command in initrd cleanup script
	cat <<-EOF > $destination/DEBIAN/control
	Package: linux-${RELEASE}-root-${DEB_BRANCH}${BOARD}
	Version: $REVISION
	Architecture: $ARCH
	Maintainer: $MAINTAINER <$MAINTAINERMAIL>
	Installed-Size: 1
	Section: kernel
	Priority: optional
	Depends: bash, linux-base, u-boot-tools, initramfs-tools
	Provides: armbian-bsp
	Conflicts: armbian-bsp
	Replaces: base-files, mpv, lightdm-gtk-greeter, armbian-tools-$RELEASE
	Recommends: bsdutils, parted, python3-apt, util-linux, toilet
	Description: Armbian tweaks for $RELEASE on $BOARD ($BRANCH branch)
	EOF

	# set up pre install script
	cat <<-EOF > $destination/DEBIAN/preinst
	#!/bin/sh
	[ "\$1" = "upgrade" ] && touch /var/run/.reboot_required
	[ -d "/boot/bin.old" ] && rm -rf /boot/bin.old
	[ -d "/boot/bin" ] && mv -f /boot/bin /boot/bin.old
	if [ -L "/etc/network/interfaces" ]; then
		cp /etc/network/interfaces /etc/network/interfaces.tmp
		rm /etc/network/interfaces
		mv /etc/network/interfaces.tmp /etc/network/interfaces
	fi
	# make a backup since we are unconditionally overwriting this on update
	[ -f "/etc/default/cpufrequtils" ] && cp /etc/default/cpufrequtils /etc/default/cpufrequtils.dpkg-old
	dpkg-divert --package linux-${RELEASE}-root-${DEB_BRANCH}${BOARD} --add --rename \
		--divert /etc/mpv/mpv-dist.conf /etc/mpv/mpv.conf
	exit 0
	EOF

	chmod 755 $destination/DEBIAN/preinst

	# postrm script
	cat <<-EOF > $destination/DEBIAN/postrm
	#!/bin/sh
	[ remove = "\$1" ] || [ abort-install = "\$1" ] && dpkg-divert --package linux-${RELEASE}-root-${DEB_BRANCH}${BOARD} --remove --rename \
		--divert /etc/mpv/mpv-dist.conf /etc/mpv/mpv.conf
	systemctl disable log2ram.service armhwinfo.service >/dev/null 2>&1
	exit 0
	EOF

	chmod 755 $destination/DEBIAN/postrm

	# set up post install script
	cat <<-EOF > $destination/DEBIAN/postinst
	#!/bin/sh
	[ ! -f "/etc/network/interfaces" ] && cp /etc/network/interfaces.default /etc/network/interfaces
	ln -sf /var/run/motd /etc/motd
	rm -f /etc/update-motd.d/00-header /etc/update-motd.d/10-help-text
	if [ -f "/boot/bin/$BOARD.bin" ] && [ ! -f "/boot/script.bin" ]; then ln -sf bin/$BOARD.bin /boot/script.bin >/dev/null 2>&1 || cp /boot/bin/$BOARD.bin /boot/script.bin; fi
	rm -f /usr/local/bin/h3disp /usr/local/bin/h3consumption
	if [ ! -f "/etc/default/armbian-motd" ]; then
		cp /etc/default/armbian-motd.dpkg-dist /etc/default/armbian-motd
	fi
	if [ ! -f "/etc/default/log2ram" ]; then
		cp /etc/default/log2ram.dpkg-dist /etc/default/log2ram
	fi
	if [ -f "/etc/systemd/system/log2ram.service" ]; then
		mv /etc/systemd/system/log2ram.service /etc/systemd/system/log2ram-service.dpkg-old
	fi
	exit 0
	EOF

	chmod 755 $destination/DEBIAN/postinst

	# won't recreate files if they were removed by user
	# TODO: Add proper handling for updated conffiles
	#cat <<-EOF > $destination/DEBIAN/conffiles
	#EOF

	# copy common files from a premade directory structure
	rsync -a $SRC/packages/bsp/common/* $destination/

	# trigger uInitrd creation after installation, to apply
	# /etc/initramfs/post-update.d/99-uboot
	cat <<-EOF > $destination/DEBIAN/triggers
	activate update-initramfs
	EOF

	# configure MIN / MAX speed for cpufrequtils
	cat <<-EOF > $destination/etc/default/cpufrequtils
	ENABLE=true
	MIN_SPEED=$CPUMIN
	MAX_SPEED=$CPUMAX
	GOVERNOR=$GOVERNOR
	EOF

	# armhwinfo, firstrun, armbianmonitor, etc. config file
	cat <<-EOF > $destination/etc/armbian-release
	# PLEASE DO NOT EDIT THIS FILE
	BOARD=$BOARD
	BOARD_NAME="$BOARD_NAME"
	VERSION=$REVISION
	LINUXFAMILY=$LINUXFAMILY
	BRANCH=$BRANCH
	ARCH=$ARCHITECTURE
	IMAGE_TYPE=$IMAGE_TYPE
	BOARD_TYPE=$BOARD_TYPE
	INITRD_ARCH=$INITRD_ARCH
	KERNEL_IMAGE_TYPE=$KERNEL_IMAGE_TYPE
	EOF

	# this is required for NFS boot to prevent deconfiguring the network on shutdown
	[[ $RELEASE == xenial || $RELEASE == stretch ]] && sed -i 's/#no-auto-down/no-auto-down/g' $destination/etc/network/interfaces.default

	# armbian-config
	install -m 755 $SRC/cache/sources/armbian-config/scripts/tv_grab_file $destination/usr/bin/tv_grab_file
	install -m 755 $SRC/cache/sources/armbian-config/debian-config $destination/usr/bin/armbian-config
	install -m 755 $SRC/cache/sources/armbian-config/softy $destination/usr/bin/softy

	# install copy of boot script & environment file
	local bootscript_src=${BOOTSCRIPT%%:*}
	local bootscript_dst=${BOOTSCRIPT##*:}

	mkdir -p $destination/usr/share/armbian/
	cp $SRC/config/bootscripts/$bootscript_src $destination/usr/share/armbian/$bootscript_dst
	[[ -n $BOOTENV_FILE && -f $SRC/config/bootenv/$BOOTENV_FILE ]] && \
		cp $SRC/config/bootenv/$BOOTENV_FILE $destination/usr/share/armbian/armbianEnv.txt

	# h3disp for sun8i/3.4.x
	if [[ $LINUXFAMILY == sun8i && $BRANCH == default ]]; then
		install -m 755 $SRC/packages/bsp/{h3disp,h3consumption} $destination/usr/bin
	fi

	# add configuration for setting uboot environment from userspace with: fw_setenv fw_printenv
	if [[ -n $UBOOT_FW_ENV ]]; then
		UBOOT_FW_ENV=($(tr ',' ' ' <<< "$UBOOT_FW_ENV"))
		echo "# Device to access      offset           env size" > $destination/etc/fw_env.config
		echo "/dev/mmcblk0	${UBOOT_FW_ENV[0]}	${UBOOT_FW_ENV[1]}" >> $destination/etc/fw_env.config
	fi

	if [[ $LINUXFAMILY == sun*i* ]]; then
		install -m 755 $SRC/packages/bsp/armbian-add-overlay $destination/usr/sbin
		if [[ $BRANCH == default ]]; then
			arm-linux-gnueabihf-gcc $SRC/packages/bsp/sunxi-temp/sunxi_tp_temp.c -o $destination/usr/bin/sunxi_tp_temp
			# convert and add fex files
			mkdir -p $destination/boot/bin
			for i in $(ls -w1 $SRC/config/fex/*.fex | xargs -n1 basename); do
				fex2bin $SRC/config/fex/${i%*.fex}.fex $destination/boot/bin/${i%*.fex}.bin
			done
		fi
	fi

	if [[ ( $LINUXFAMILY == sun*i || $LINUXFAMILY == pine64 ) && $BRANCH == default ]]; then
		# add mpv config for vdpau_sunxi
		mkdir -p $destination/etc/mpv/
		cp $SRC/packages/bsp/mpv/mpv_sunxi.conf $destination/etc/mpv/mpv.conf
		echo "export VDPAU_OSD=1" > $destination/etc/profile.d/90-vdpau.sh
		chmod 755 $destination/etc/profile.d/90-vdpau.sh
	fi
	if [[ ( $LINUXFAMILY == sun50i* || $LINUXFAMILY == sun8i ) && $BRANCH == dev ]]; then
		# add mpv config for x11 output - slow, but it works compared to no config at all
		mkdir -p $destination/etc/mpv/
		cp $SRC/packages/bsp/mpv/mpv_mainline.conf $destination/etc/mpv/mpv.conf
	fi

	case $RELEASE in
	jessie)
		mkdir -p $destination/etc/NetworkManager/dispatcher.d/
		install -m 755 $SRC/packages/bsp/99disable-power-management $destination/etc/NetworkManager/dispatcher.d/
	;;
	xenial)
		mkdir -p $destination/etc/NetworkManager/conf.d/
		cp $SRC/packages/bsp/zz-override-wifi-powersave-off.conf $destination/etc/NetworkManager/conf.d/
		if [[ $BRANCH == default ]]; then
			# this is required only for old kernels
			# not needed for Stretch since there will be no Stretch images with kernels < 4.4
			mkdir -p $destination/lib/systemd/system/haveged.service.d/
			cp $SRC/packages/bsp/10-no-new-privileges.conf $destination/lib/systemd/system/haveged.service.d/
		fi
	;;

	stretch)
		mkdir -p $destination/etc/NetworkManager/conf.d/
		cp $SRC/packages/bsp/zz-override-wifi-powersave-off.conf $destination/etc/NetworkManager/conf.d/
	;;
	esac

	# execute $LINUXFAMILY-specific tweaks
	[[ $(type -t family_tweaks_bsp) == function ]] && family_tweaks_bsp

	# add some summary to the image
	fingerprint_image "$destination/etc/armbian.txt"

	# create board DEB file
	display_alert "Building package" "$CHOSEN_ROOTFS" "info"
	dpkg-deb -b $destination ${destination}.deb
	mkdir -p $DEST/debs/$RELEASE/
	mv ${destination}.deb $DEST/debs/$RELEASE/
	# cleanup
	rm -rf $destination
}
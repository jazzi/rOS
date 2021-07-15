#!/bin/bash

trap exit INT

SECONDS=0

features=$( cat /boot/features )
versions=( $( cat /boot/versions ) )
version=${versions[0]}
revision=${versions[1]}
uibranch=${versions[2]}
col=${versions[3]}
rpi01=${versions[4]}

banner() {
	echo
	def='\e[0m'
	bg='\e[44m'
    printf "$bg%*s$def\n" $col
    printf "$bg%-${col}s$def\n" "  $1"
    printf "$bg%*s$def\n" $col
}

banner 'Initialize Arch Linux Arm ...'

pacman-key --init
pacman-key --populate archlinuxarm

rm -f /var/lib/pacman/db.lck  # in case of rerun

# fill entropy pool (fix - Kernel entropy pool is not initialized)
systemctl start systemd-random-seed

title="Create rOS $version"
optbox=( --colors --no-shadow --no-collapse )
opt=( --backtitle "$title" ${optbox[@]} )

dialog "${optbox[@]}" --infobox "


                       \Z1r\Z0Audio $version
" 9 58
sleep 2

clear -x # needed: fix stdout not scroll
#----------------------------------------------------------------------------
banner 'Upgrade kernel and default packages ...'

packages='alsa-utils cava cronie cd-discid dosfstools gifsicle hfsprogs i2c-tools imagemagick inetutils jq mpc mpd mpdscribble '
packages+='nfs-utils nginx-mainline-pushstream nss-mdns ntfs-3g parted php-fpm sshpass sudo udevil wget wiringpi '

if [[ -e /boot/kernel8.img ]]; then
	pacman -R --noconfirm linux-aarch64 uboot-raspberrypi
	packages+='linux-raspberrypi4 raspberrypi-bootloader raspberrypi-bootloader-x raspberrypi-firmware '
fi

# add +R repo
if ! grep -q '^\[+R\]' /etc/pacman.conf; then
	sed -i '/\[core\]/ i\
[+R]\
SigLevel = Optional TrustAll\
Server = https://rern.github.io/$arch\
' /etc/pacman.conf
fi

pacman -Syu --noconfirm
[[ $? != 0 ]] && pacman -Syu --noconfirm

banner 'Install packages ...'

pacman -S --noconfirm --needed $packages $features
[[ $? != 0 ]] && pacman -S --noconfirm --needed $packages $features

banner 'Get configurations and user interface ...'

wget -q --show-progress https://github.com/rern/rOS/archive/main.zip -O config.zip
wget -q --show-progress https://github.com/rern/rAudio-$version/archive/$uibranch.zip -O ui.zip
mkdir -p /tmp/config
bsdtar --strip 1 -C /tmp/config -xvf config.zip
bsdtar --strip 1 -C /tmp/config -xvf ui.zip
rm *.zip /tmp/config/*.* /tmp/config/.* 2> /dev/null

chmod -R go-wx /tmp/config
chmod -R u+rwX,go+rX /tmp/config
cp -r /tmp/config/* /
chown http:http /etc/fstab
chown -R http:http /etc/netctl /etc/systemd/network /srv/http
chmod 755 /srv/http/* /srv/http/bash/* /srv/http/settings/*

if [[ -n $rpi01 ]]; then
	sed -i '/^.Service/,$ d' /etc/systemd/system/mpd.service.d/override.conf
	sed -i '/ExecStart=/ d' /etc/systemd/system/spotifyd.service.d/override.conf
	rm -rf /etc/systemd/system/{shairport-sync,upmpdcli}.service.d
fi
if [[ -e /boot/kernel8.img ]]; then
	partuuidROOT=$( blkid | awk '/LABEL="ROOT"/ {print $NF}' | tr -d '"' )
	cat << EOF > /boot/cmdline.txt
root=$partuuidROOT rw rootwait selinux=0 plymouth.enable=0 smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0 ipv6.disable=1 fsck.repair=yes isolcpus=3 console=tty1
EOF
	cat << EOF > /boot/config.txt
gpu_mem=32
initramfs initramfs-linux.img followkernel
max_usb_current=1
disable_splash=1
disable_overscan=1
dtparam=krnbt=on
dtparam=audio=on
EOF
fi
#---------------------------------------------------------------------------------
banner 'Configure ...'

# alsa
alsactl store
# bluetooth
if [[ -e /usr/bin/bluetoothctl ]]; then
	sed -i 's/#*\(AutoEnable=\).*/\1true/' /etc/bluetooth/main.conf
else
	rm -rf /etc/systemd/system/{bluealsa,bluetooth}.service.d
	rm -f /etc/systemd/system/blue*
fi
# chromium
if [[ -e /usr/bin/chromium ]]; then
	sed -i 's/\(console=\).*/\1tty3 quiet loglevel=0 logo.nologo vt.global_cursor_default=0/' /boot/cmdline.txt # boot splash
	chmod 775 /etc/X11/xorg.conf.d                   # fix permission for rotate file
	ln -sf /srv/http/bash/xinitrc /etc/X11/xinit     # startx
	mv /usr/share/X11/xorg.conf.d/{10,45}-evdev.conf # reorder
	ln -sf /srv/http/bash/xinitrc /etc/X11/xinit     # script
	systemctl daemon-reload
	systemctl disable getty@tty1                     # login prompt
	systemctl enable bootsplash localbrowser
else
	rm -f /etc/systemd/system/{bootsplash,localbrowser}* /etc/X11/* /srv/http/assets/img/{splah,CW,CCW,NORMAL,UD}* /srv/http/bash/xinitrc /usr/local/bin/ply-image 2> /dev/null
fi
# cron - for addons updates
( crontab -l &> /dev/null; echo '00 01 * * * /srv/http/bash/cmd.sh addonsupdates &' ) | crontab -
# hostapd
[[ ! -e /usr/bin/hostapd ]] && rm -rf /etc/{hostapd,dnsmasq.conf}
# mpd
cp /usr/share/mpdscribble/mpdscribble.conf.example /etc/mpdscribble.conf
# motd
ln -sf /srv/http/bash/motd.sh /etc/profile.d/
#mpdscribble
sed -i 's/User=.*/User=mpd/' /usr/lib/systemd/system/mpdscribble@.service
# pam - fix freedesktop.home1.service not found (upgrade somehow overwrite)
sed -i '/^-.*pam_systemd_home/ s/^/#/' /etc/pam.d/system-auth
# password
echo root:ros | chpasswd
# user - set expire to none
users=$( cut -d: -f1 /etc/passwd )
for user in $users; do
	chage -E -1 $user
done
# sshd
sed -i -e 's/\(PermitEmptyPasswords \).*/#\1no/
' -e 's/.*\(PrintLastLog \).*/\1no/
' /etc/ssh/sshd_config
# samba
[[ -e /usr/bin/smbd ]] && ( echo ros; echo ros ) | smbpasswd -s -a root
# no shairport-sync
[[ ! -e /usr/bin/shairport-sync ]] && rm /etc/sudoers.d/shairport-sync /etc/systemd/system/shairport-meta.service
# no snapcast
[[ ! -e /usr/bin/snapclient ]] && rm /etc/default/snapclient
# no spotifyd
[[ ! -e /usr/bin/spotifyd ]] && rm /etc/spotifyd.conf
# no upmpdcli
[[ ! -e /usr/bin/upmpdcli ]] && rm -rf /etc/upmpdcli.conf /etc/systemd/system/upmpdcli.service.d
# wireless-regdom
echo 'WIRELESS_REGDOM="00"' > /etc/conf.d/wireless-regdom
# default startup services
systemctl daemon-reload
systemctl enable avahi-daemon cronie devmon@http nginx php-fpm startup

#---------------------------------------------------------------------------------
# data - settings directories
/srv/http/bash/datareset.sh $version $revision
# remove files and package cache
rm /boot/{features,versions} /etc/motd /root/create-ros.sh /var/cache/pacman/pkg/*
# usb boot - disable sd card polling
! df | grep -q /dev/mmcblk && echo 'dtoverlay=sdtweak,poll_once' >> /boot/config.txt
# expand partition
touch /boot/expand
# build version
version=$( cat $ROOT/srv/http/data/system/version )
if [[ -e /boot/kernel8.img ]]; then
	model=64
elif [[ -e /boot/bcm2711-rpi-4-b.dtb ]]; then
	model=4
elif [[ -e /boot/kernel7.img ]]; then
	model=2-3
else
	model=0-1
fi
kernel=$( uname -r | sed 's/-ARCH//' )
echo rAudio-$version-RPi$model-$kernel > /srv/http/data/system/build

dialog "${optbox[@]}" --infobox "

            \Z1r\Z0Audio $version created successfully.

                       \Z1Reboot\Z0 ...

$( date -d@$SECONDS -u +%M:%S )
" 9 58

shutdown -r now

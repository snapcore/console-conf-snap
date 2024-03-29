#!/bin/bash

set -e
set -x

shopt -s nullglob

# include auxiliary functions from this script
. "$TESTSLIB/prepare-utils.sh"

# install dependencies
install_base_deps

# build the console-conf snap if it has not been provided to us by CI
artifacts=("$PROJECT_PATH"/console-conf_*.snap)
artifacts_cnt="${#artifacts[@]}"
if [ "$artifacts_cnt" -eq 0 ]; then
    echo "no console-conf artifact"
    exit 1
elif [ "$artifacts_cnt" -gt 1 ]; then
    echo "found more than one console-conf artifact: ${artifacts[*]}"
    exit 1
else
    # use provided core24 snap
    cp "${artifacts[0]}" "$(get_snap_name)"
fi

# download snaps required for us to build the image
download_core24_snaps

# create test user for spread to use
groupadd --gid 12345 test
adduser --uid 12345 --gid 12345 --disabled-password --gecos '' test

if getent group systemd-journal >/dev/null; then
    usermod -G systemd-journal -a test
    id test | MATCH systemd-journal
fi

echo 'test ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# re-pack snapd snap with special systemd service which runs during run
# mode to create a user for us to inspect the system state

# TODO actually create a user if needed

snapddir=/tmp/snapd-workdir
unsquashfs -d $snapddir upstream-snapd.snap

# inject systemd service to setup users and other tweaks for us
# these are copied from upstream snapd prepare.sh, slightly modified to not 
# extract snapd spread data from ubuntu-seed as we don't need all that here
cat > "$snapddir/lib/systemd/system/snapd.spread-tests-run-mode-tweaks.service" <<'EOF'
[Unit]
Description=Tweaks to run mode for spread tests
Before=snapd.service
Documentation=man:snap(1)
[Service]
Type=oneshot
ExecStart=/usr/lib/snapd/snapd.spread-tests-run-mode-tweaks.sh
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
EOF

cat > "$snapddir/usr/lib/snapd/snapd.spread-tests-run-mode-tweaks.sh" <<'EOF'
#!/bin/sh
set -e
# Print to kmsg and console
# $1: string to print
print_system()
{
    printf "%s spread-tests-run-mode-tweaks.sh: %s\n" "$(date -Iseconds --utc)" "$1" |
        tee -a /dev/ttyS0 /run/mnt/ubuntu-seed/spread-tests-run-mode-tweaks-log.txt || true
}
# ensure we don't enable ssh in install mode or spread will get confused
if ! grep 'snapd_recovery_mode=run' /proc/cmdline; then
    print_system "not in run mode - script not running"
    exit 0
fi
if [ -e /root/spread-setup-done ]; then
    print_system "already ran, not running again"
    exit 0
fi
print_system "in run mode, not run yet, extracting overlay data"
# extract data from previous stage
if [ -f /run/mnt/ubuntu-seed/run-mode-overlay-data.tar.gz ]; then
   (cd / && tar xf /run/mnt/ubuntu-seed/run-mode-overlay-data.tar.gz)
   cp -r /root/test-var/lib/extrausers /var/lib
   # user db - it's complicated
   for f in group gshadow passwd shadow; do
       # now bind mount read-only those passwd files on boot
       if [ ! -f /root/test-etc/$f ]; then
          continue
       fi
       cat >/etc/systemd/system/etc-"$f".mount <<EOF2
[Unit]
Description=Mount root/test-etc/$f over system etc/$f
Before=ssh.service
[Mount]
What=/root/test-etc/$f
Where=/etc/$f
Type=none
Options=bind,ro
[Install]
WantedBy=multi-user.target
EOF2
        systemctl enable etc-"$f".mount
        systemctl start etc-"$f".mount
    done
fi
# TODO: do we need this for our nested VM? We don't login as root to the nested
#       VM...
sed -i 's/\#\?\(PermitRootLogin\|PasswordAuthentication\)\>.*/\1 yes/' /etc/ssh/sshd_config
echo "MaxAuthTries 120" >> /etc/ssh/sshd_config
grep '^PermitRootLogin yes' /etc/ssh/sshd_config
systemctl reload ssh || true
print_system "done setting up ssh for spread test user"
touch /root/spread-setup-done
EOF
chmod 0755 "$snapddir/usr/lib/snapd/snapd.spread-tests-run-mode-tweaks.sh"

# since we're testing console-conf snap which was built by the PR job, we need
# to establish the required connections manually, hence inject a service which
# will wait for the seeding to complete and then run snap connect, lastly it
# will print a message to the serial (/dev/ttyS0) so that we can synchronize
# with it in the test

cat > "$snapddir/lib/systemd/system/snapd.spread-tests-console-conf-tweaks.service" <<'EOF'
[Unit]
Description=Tweaks to console-conf
Before=console-conf@tty1.service
Before=serial-console-conf@ttyS0.service
[Service]
Type=simple
ExecStart=/usr/lib/snapd/snapd.spread-tests-console-conf-tweaks.sh
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
EOF

cat > "$snapddir/usr/lib/snapd/snapd.spread-tests-console-conf-tweaks.sh" <<'EOF'
#!/bin/sh
set -e
# Print to kmsg and console
# $1: string to print
print_system()
{
    printf "%s spread-tests-console-conf-tweaks.sh: %s\n" "$(date -Iseconds --utc)" "$1" |
        tee -a /dev/ttyS0 /run/mnt/ubuntu-seed/spread-tests-console-conf-log.txt || true
}
# ensure we don't enable ssh in install mode or spread will get confused
if ! grep 'snapd_recovery_mode=run' /proc/cmdline; then
    print_system "console-conf-tweaks: not in run mode - script not running"
    exit 0
fi
if [ -e /root/spread-console-conf-done ]; then
    print_system "console-conf-tweaks: already ran, not running again"
    exit 0
fi
print_system "console-conf-tweaks: in run mode, not run yet"

while ! snap wait system seed.loaded; do
      print_system "console-conf-tweaks: waiting for snapd seeding"
      sleep 1
done
print_system "console-conf-tweaks: snapd seeding done"

snap connect console-conf:terminal-control console-conf:terminal-devices
snap connect console-conf:hardware-observe
snap connect console-conf:network-observe
snap connect console-conf:network-setup-control
snap connect console-conf:network-control
snap connect console-conf:snapd-control
snap connect console-conf:run-console-conf
snap connect console-conf:var-log-console-conf
print_system "$(snap connections console-conf)"
print_system ">>>> console-conf tweaks done <<<<"

touch /root/spread-console-conf-done
EOF
chmod 0755 "$snapddir/usr/lib/snapd/snapd.spread-tests-console-conf-tweaks.sh"

rm upstream-snapd.snap
snap pack --filename=upstream-snapd.snap "$snapddir"
rm -r $snapddir

# repack gadget to disable refreshes
gadgetdir=/tmp/gadget-workdir
unsquashfs -d "$gadgetdir" upstream-pc-gadget.snap

cat <<EOF >> "$gadgetdir/meta/gadget.yaml"
defaults:
  system:
    refresh:
      hold: forever
EOF

snap pack --filename=upstream-pc-gadget.snap "$gadgetdir"
rm -rf "$gadgetdir"

# finally build the uc image
build_base_image

# the image is now ready to be booted
mv pc.img "$PROJECT_PATH/pc.img"

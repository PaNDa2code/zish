#!/bin/bash

# Check if the script is run with root privileges
if [ "$(id -u)" -ne 0 ]; then
	echo "Please run this script with sudo or as root."
	exit 1
fi

# Get the current user
current_user="$(logname)"

# Enable autologin
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<EOL
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $current_user --noclear %I \$TERM
EOL

# Add Xorg start script to .bash_profile or .zprofile
for shell_profile in ".bash_profile" ".zprofile"; do
	profile_file="/home/$current_user/$shell_profile"
	touch $profile_file
	if ! grep -q "exec startx" $profile_file; then
		cat >>$profile_file <<EOL

if [[ -z \$DISPLAY ]] && [[ \$(tty) = /dev/tty1 ]]; then
  exec startx
fi
EOL
	fi
done

# Set the correct owner and permissions for the profile files
chown $current_user:$current_user /home/$current_user/.bash_profile /home/$current_user/.zprofile
chmod 644 /home/$current_user/.bash_profile /home/$current_user/.zprofile

# Reload systemd configuration and reboot
systemctl daemon-reload
echo "Configuration done. Reboot your system for the changes to take effect."

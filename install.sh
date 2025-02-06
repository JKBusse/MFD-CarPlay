#!/bin/sh
# This is a comment!
sudo mv config.txt /boot/firmware/config.txt # Move the config.txt file to the boot partition
sudo mv carplay.service /etc/systemd/system/carplay.service # Move the carplay.service file to the systemd directory

cd /usr/local/bin 
mkdir MFD-CarPlay # Create a directory for CarPlay
cd MFD-CarPlay
wget https://github.com/rhysmorgan134/react-carplay/releases/download/v4.0.5/react-carplay-4.0.5-arm64.AppImage # Download the latest release of React-CarPlay
chmod +x react-carplay-4.0.5-arm64.AppImage # Make the AppImage executable
FILE=/etc/udev/rules.d/52-nodecarplay.rules echo "SUBSYSTEM==\"usb\", ATTR{idVendor}==\"1314\", ATTR{idProduct}==\"152*\", MODE=\"0660\", GROUP=\"plugdev\"" | sudo tee $FILE # Add a udev rule for the CarPlay dongle
sudo raspi-config nonint do_wayland W1 # Set the display manager to X11
sudo systemctl restart lightdm.service # Restart the display manager to apply the change to X11
sudo raspi-config nonint do_vnc 0 -y # Enable VNC
sudo raspi-config nonint do_boot_behaviour B4 # Set the boot behaviour to Desktop with autologin

sudo systemctl enable carplay.service # Enable the CarPlay service

sleep 5 # Wait 5 sec. before rebooting
sudo reboot # Reboot the Raspberry Pi
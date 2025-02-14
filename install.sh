#!/bin/sh
# This is a comment!
sudo apt-get update -y # Update the package list
sudo apt-get upgrade -y # Upgrade the installed packages
sudo apt-get install libxi-dev libx11-dev libxrandr-dev txt2man -y # Install the required packages for the touch calibration tool
sudo mv config.txt /boot/firmware/config.txt # Move the config.txt file to the boot partition
sudo mv carplay.service /etc/systemd/system/carplay.service # Move the carplay.service file to the systemd directory

cd /usr/local/bin 
mkdir MFD-CarPlay # Create a directory for CarPlay
cd MFD-CarPlay
wget https://github.com/rhysmorgan134/react-carplay/releases/download/v4.0.5/react-carplay-4.0.5-arm64.AppImage # Download the latest release of React-CarPlay
chmod +x react-carplay-4.0.5-arm64.AppImage # Make the AppImage executable
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="1314", ATTR{idProduct}=="152*", MODE="0660", GROUP="plugdev"' | sudo tee /etc/udev/rules.d/52-nodecarplay.rules > /dev/null # Add a udev rule for CarPlay Dongle
sudo raspi-config nonint do_wayland W1 # Set the display manager to X11
sudo systemctl restart lightdm.service # Restart the display manager to apply the change to X11
sudo raspi-config nonint do_vnc 0 -y # Enable VNC
sudo raspi-config nonint do_boot_behaviour B4 # Set the boot behaviour to Desktop with autologin

sudo systemctl enable carplay.service # Enable the CarPlay service
sudo sh -c "echo -n uvcvideo.quirks=2 >> /boot/firmware/cmdline.txt # Add the uvcvideo quirks for rvc

sleep 5 # Wait 5 sec. before rebooting
sudo reboot # Reboot the Raspberry Pi
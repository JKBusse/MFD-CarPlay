#!/bin/sh
# This is a comment!
sudo apt-get update -y # Update the package list
sudo apt-get upgrade -y # Upgrade the installed packages
sudo apt-get install libxi-dev libx11-dev libxrandr-dev txt2man -y # Install the required packages for the touch calibration tool
sudo mv config.txt /boot/firmware/config.txt # Move the config.txt file to the boot partition

cd /home/pi/desktop # Change to the Desktop directory
git clone https://github.com/kreijack/xlibinput_calibrator.git
cd xlibinput_calibrator/src/
make

cd /home/pi/Downloads # Change to the Downloads directory
curl -LO https://raw.githubusercontent.com/f-io/pi-carplay/main/setup-pi.sh # Download the CarPlay setup script
sudo chmod +x setup-pi.sh   # Make the CarPlay setup script executable
./setup-pi.sh   # Run the CarPlay setup script

#sudo raspi-config nonint do_wayland W1 # Set the display manager to X11
#sudo systemctl restart lightdm.service # Restart the display manager to apply the change to X11
#sudo raspi-config nonint do_vnc 0 -y # Enable VNC
sudo raspi-config nonint do_boot_behaviour B4 # Set the boot behaviour to Desktop with autologin

sudo sh -c "echo -n uvcvideo.quirks=2 >> /boot/firmware/cmdline.txt" # Add the uvcvideo quirks for rvc

sleep 5 # Wait 5 sec. before rebooting
sudo reboot #Reboot the Raspberry Pi
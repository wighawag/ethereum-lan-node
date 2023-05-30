## Setting up a Raspberry PI with switchable Access Point 

From https://raspberryconnect.co.uk/projects/65-raspberrypi-hotspot-accesspoints/183-raspberry-pi-automatic-hotspot-and-static-hotspot-installer

An easy installer script for my AutoHotspot and Static Hotspot setups.  Allows a Raspberry Pi to automatically create a WiFi Hotspot when you are out or connect to your home network when you are home.

This script is for installing a Raspberry Pi WiFi setup where the Pi will connect to a previously configured Wifi network when the Pi is in range of the router or Automatically setup a Raspberry Pi WiFi access point when a known wifi network is not in range.
This can also be run manually or with a timer to switch without a reboot.

There are three guides on this website which show the steps on how to install a permanent static access point or two setups that can switch between a Raspberry Pi access point or WiFi network connection without a reboot.

These three guides are now available in an Installer. This guide goes through the steps to setup the installer and what features are available.
Tested on PiOS Bullseye and Buster
Intro:

If you have not used the Autohotspot setup's before here is a brief intro to what they can do.
Aim:

- When you're home:   On starting the Raspberry Pi it connects to your home routers wifi
- When you're out: On starting, if any known wifi connection is not found it will generate an access point so a direct wifi connection can be made to the Raspberry Pi by a tablet, phone or laptop.
- While in access point mode:  if an ethernet cable is connected the Raspberry Pi, then it will have network/internet access along with any wifi device connected to the access point.

Additional Features:

Using a Cron, a timer can be setup so the wifi connection can be regularly checked. It will switch between a wifi router and a access point without a reboot depending on the results. This is useful for

- Raspberry Pi in car entertainment systems
- Raspberry Pi Dash Cams
- If the RPi looses wifi connection in your garden or near your home when using the camera or sensors.
- You run a script or program at home connected to your router and wish to monitor it while you are out. As a hotspot is generated without a reboot the script/program is not interrupted.

It is also possible to run the script from a GPIO button so you can manually run the script to switch depending on where you are.

### Requirements:

This has been tested on PiOS Bullseye (11) & Buster (10). To see which version you have enter the command lsb_release -a. The scripts via the manual guides below have been tested on Jessie and Stretch and work fine, just this installer has only been tested on Bullseye & Buster.  I would say it should work fine on Stretch and Jessie but a computer is involved so you can never be sure!

- Raspberry Pi 3, RPi 3 B+, RPi4
- Raspberry Pi 1 or 2 with a Wifi Dongle*,
- Raspberry Pi Zero W, Zero 2 and Zero with WiFi Dongle* (internet hotspot not useable as it has no ethernet port.
- Wifi already configured for your home router

> *some WiFi dongles don't work in adhoc mode or don't work with with the nl80211 driver used in this guide for RPi4, RPi 3, RPi 3B+, Pi Zero W  & Pi Zero 2 inbuilt wifi, so you may want to check this first before starting

The manual guides can be found here:

- Autohotspot with Net Access  https://www.raspberryconnect.com/projects/65-raspberrypi-hotspot-accesspoints/157-raspberry-pi-auto-wifi-hotspot-switch-internet
- Autohotspot with NO Net Access  https://www.raspberryconnect.com/projects/65-raspberrypi-hotspot-accesspoints/158-raspberry-pi-auto-wifi-hotspot-switch-direct-connection
- Permanent Static Hotspot with Internet access  https://www.raspberryconnect.com/projects/65-raspberrypi-hotspot-accesspoints/168-raspberry-pi-hotspot-access-point-dhcpcd-method

Also available at https://github.com/RaspberryConnect/AutoHotspot-Installer
 Installer:

To use the installer:

open a terminal screen

Download the AutoHotspot-Setup.tar.xz archive to the current folder using the command

```
curl "https://www.raspberryconnect.com/images/hsinstaller/Autohotspot-Setup.tar.xz" -o AutoHotspot-Setup.tar.xz
```

Unarchive the file to the curent folder using the command

```
tar -xvJf AutoHotspot-Setup.tar.xz
```

If you are using the Desktop then you can right click on the AutoHotspot-Setup.tar.xz file and select Extract Here

change directory to the Autohotspot folder with

```
cd Autohotspot
```

Run the script with the command

```
sudo ./autohotspot-setup.sh
```

This script will fail if sudo is not used.

You will presented with these menu option:

- 1 = Install Autohotspot with eth0 access for Connected Devices
- 2 = Install Autohotspot with No eth0 for connected devices
- 3 = Install a Permanent Access Point with eth0 access for connected devices
- 4 = Uninstall Autohotspot or permanent access point
- 5 = Add a new wifi network to the Pi (SSID) or update the password for an existing one.
- 6 = Autohotspot: Force to an access point or connect to WiFi network if a known SSID is in range
- 7 = Change the access points SSID and password
- 8 = Exit

### Option 1: Install Autohotspot with eth0 access for Connected Devices

Once installed and after a reboot the Raspberry Pi will connect to a router that has previously been connected to and is listed in /etc/wpa_supplicant/wpa_supplicant.conf. If no router is in range then it will generate a WiFi access point.
This will have an SSID of RPiHotspot and password of 1234567890
Use option 7 to change the access point password and also the SSID if required
If an ethernet cable is connected to the Pi with access to the internet then it will allow devices connected to the access point to connect to the internet or local network.
Once a connection to the access point has been made you can access the Raspberry Pi via ssh & VNC with
ssh pi@192.168.50.5
vnc: 192.168.50.5::5900
for webservers use http://192.168.50.5/

### Option 2: Install Autohotspot with No eth0 for connected devices

This option is similar to option 1 but connected devices have no network/internet connection if an ethernet cable is connected.
The Pi itself can use the eth0 connection and also be accessed from a device on the etho network.
This has been designed so you can access only the Pi from a Laptop, tablet or phone.
The access point SSID will be RPiHotspot with a password of 1234567890
Once a connection to the access point has been made you can access the Raspberry Pi via ssh & VNC with
ssh pi@10.0.0.5
vnc: 10.0.0.5::5900
for webservers use http://10.0.0.5/

### Option 3: Install a Permanent Access Point with eth0 access for connected devices

This is for a permanent WiFi access point with network/internet access for connected devices.
The Raspberry Pi will only have network and internet access when an ethernet cable is connected.
Once a connection to the access point has been made, you can access the Raspberry Pi via ssh & VNC with
ssh pi@192.168.50.10
vnc: 192.168.50.10::5900
for webservers use http://192.168.50.10/

Additional setup is required if you wanted to use a second WiFi device to connect to the internet rather than a ethernet conection. This is a planned future option.

### Option 4: Uninstall Autohotspot or Permanent Access Point

This will disable the setup of any of the three setups and return the Raspberry Pi to default Wifi settings.
Hostapd & dnsmasq will not be uninstalled just disabled. This is so a hotspot setup can be re-installed without access to the internet.  

### Option 5: Add a new wifi network to the Pi (SSID) or update the password for an existing one

If you are using either of the autohotspot setups in access point mode and wish to connect to a local WiFi network. You will be unable to scan for any networks as the desktop wifi option will be disabled, shown as red crosses. You can manually add the details to /etc/wpa_supplicant/wpa_supplicant.conf if you know them.
This option will allow you to scan for local WiFi networks and update the Pi. If you then reboot or use the Force... option 6 ,see below.
This option only works for WiFi networks where only a password is required. If a username is required this will not work.

### Option 6: Autohotspot: Force to an access point or Force to WiFi network if a known SSID is in range

This option is only for the Autohotspot setups.
If you are at home and connected to your home network but would like to use the hotspot. This option will force the pi to access point mode and will ignore your home network untill the next reboot. If you use this option again while in access point mode, it will attempt to connect to a known WiFi network. This will go back to the access point if no valid WiFi network is found or there is a connection issue.

### Option 7: Change the Pi's access point SSID and Password

By default the access point SSID is RPiHotSpot with a password of 1234567890. Use this option to change either or both SSID and Password.
You will be prompted to change both but if you make no entry and press enter the existing setting will be kept.
The password must be at least 8 characters.

### Option 8: Exit

Exit the script.
Complete the Setup:

If you have installed a hotspot setup with options, 1,2 or 3 then Reboot to activate the setup.

To test the Hotspot mode for the Autohotspot setups;  run the installer again and select option 6 to force the Pi into Hotspot mode. You can then test that everything is working ok.

When you have finished either choose option 6 again to reconnect to your router or reboot.
Switching Setups:

You can switch between options 1,2 & 3 at anytime. All configuration will be changed removing the config of the previous setup. Just be aware that each setup has a different IP address for the access point. If you have changed the access points SSID from RPiHotspot or the password from 1234567890 (which is a good idea) it will be reset back to the defaults.

If you find this guide useful and wish to show your appreciation then you are welcome to make a donation or share a link to this article. There is no obligation to do so, this guide is free for use and support is available to everybody as long as I know the answer :)
RaspberryConnect.com

 
 
### Trouble Shooting

If you are in range of your router but the Pi will only create a hotspot even after a reboot then there will be an issue with connecting to your router. This can be caused by an incorrect password or interference especially if you are using 5Mhz wifi on a PI 3B+ or Pi4. 

To check the password either use option 5 or check /etc/wpa_supplicant/wpa_supplicant.conf

If your are having interference issues or believe this setup is the cause then use option 4 to uninstall the setup. Reboot and try your Pi again. If you still have a connection issue it will be an issue within your home network.

If it is this setup then it may be the format of your SSID from your router. It can contain spaces and special characters but not a comma. so "My SSID" will be fine but "My,SSID" will fail.

If your wpa_supplicant.conf file was created using a text editor on Microsoft Windows, though Cr (Carrage Returns) are handled,  there may be hidden formatting characters other than Cr that are causing the issue. Either just use notepad on Windows or backup and delete /etc/wpa_supplicant/wpa_supplicant.conf and create it again using the Raspbian desktop Wifi settings. Headerless setups can setup WiFi networks in raspi-config.  Option 5 will only work if wpa_supplicant.conf already exists.
/etc/network/interfaces file:

many older access points and network setup guides online add entries to the /etc/network/interfaces file. This file is depreciated in Raspbian & PiOS. Any entry in this file is not compatible with these setups. This installer backup and remove any entries found in this file. They will be restored if the uninstall option is used.
 Video Guide on using the Installer

On this video I go through following the steps in this guide and setting up a static acces point and a autohotspot, then how to connect to the access points on a tablet.
## Setting up the Raspberry pi zero 2 w as an Wifi Access Point (while keeping its own access to internet)

We follow the doc here: https://blog.thewalr.us/2017/09/26/raspberry-pi-zero-w-simultaneous-ap-and-managed-mode-wifi/

Create the file `/etc/udev/rules.d/70-persistent-net.rules` with the following content:


```
SUBSYSTEM=="ieee80211", ACTION=="add|change", ATTR{macaddress}=="b8:27:eb:ff:ff:ff", KERNEL=="phy0", \
  RUN+="/sbin/iw phy phy0 interface add ap0 type __ap", \
  RUN+="/bin/ip link set ap0 address b8:27:eb:ff:ff:ff"
```

> 
> Note: replace `b8:27:eb:ff:ff:ff` with your mac address 
> 
> you can get your MAC address via the command
> 
> ```
> iw dev
> ```
> 
> check the  `Interface wlan0` section
> 
> Keep also note of the channel used


```bash
sudo apt-get install dnsmasq hostapd
```

Then modify `/etc/dnsmasq.conf` to add the following at the end of the file

```
interface=lo,ap0
no-dhcp-interface=lo,wlan0
bind-interfaces
server=8.8.8.8
domain-needed
bogus-priv
dhcp-range=192.168.10.50,192.168.10.150,12h
```

> Note we use 8.8.8.8 as DNS but feel free to use any you want

Then we modify (or create most likely) `/etc/hostapd/hostapd.conf` to get the following content

```
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
interface=ap0
driver=nl80211
ssid=YourApNameHere
hw_mode=g
channel=11
wmm_enabled=0
macaddr_acl=0
auth_algs=1
wpa=2
wpa_passphrase=YourPassPhraseHere
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP CCMP
rsn_pairwise=CCMP
```

> Note replace `YourApNameHere` and `YourPassPhraseHere` with sonmething of your choice
> 
> Also it might be a good idea to use the same channel as found with `iw dev` instead of the `11` there above

Finally we modify `/etc/default/hostapd` to set `DAEMON_CONF`

```bash
DAEMON_CONF="/etc/hostapd/hostapd.conf"
```

We can now configure our `/etc/wpa_supplicant/wpa_supplicant.conf` to add network to be connected to in normal (non-AP mode)

it should contains the current wlan0 configuration if you are connected via wifi

Add a `id_str="<AP_NAME>"` to each like so:

```
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
        ssid="WHATEVER_SSID_YOU_HAVE_CONFIGURED"
        psk=PRIVATE_KEY_IF_ANY
        id_str="AP_1"
}

network={
        ssid="ANOTHER_SSID"
        psk=PRIVATE_KEY_IF_ANY
        id_str="AP_2"
}
```

AP_1 and AP_2 can then be used later as you ll see. You can name whatever you want like AP_HOME AP_EVENT

We then modify `/etc/network/interfaces` and append the following

```
auto lo
auto ap0
auto wlan0
iface lo inet loopback

allow-hotplug ap0
iface ap0 inet static
    address 192.168.10.1
    netmask 255.255.255.0
    hostapd /etc/hostapd/hostapd.conf

allow-hotplug wlan0
iface wlan0 inet manual
    wpa-roam /etc/wpa_supplicant/wpa_supplicant.conf
iface AP_1 inet dhcp
iface AP_2 inet dhcp
```
> Note `AP_1` and `AP_2` : remove or add any you need

Now if you reboot, it appears tha there is sometime issues (see https://blog.thewalr.us/2017/09/26/raspberry-pi-zero-w-simultaneous-ap-and-managed-mode-wifi/)


To make it work, we create a script: `/usr/local/bin/start-ap-managed-wifi.sh` with the following content:

```bash
#!/bin/bash
sleep 30
sudo ifdown --force wlan0 && sudo ifdown --force ap0 && sudo ifup ap0 && sudo ifup wlan0
```

Then create a cron job

```
sudo crontab -e
```

using this line:

```cron
@reboot /usr/local/bin/start-ap-managed-wifi.sh
```

30 seconds should be enough?

```
sudo reboot
```


## Briding your AP to internet 

This is optional and probably not recommended as you do not want to have your ethereum node used as a gateway

```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s 192.168.10.0/24 ! -d 192.168.10.0/24 -j MASQUERADE
sudo systemctl restart dnsmasq
```

You'll need to append these lines to the script above: `/usr/local/bin/start-ap-managed-wifi.sh`


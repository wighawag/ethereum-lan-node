# ethereum-lan-node
A node for LAN network


# Raspberry PI

We assume you have the networking configured. Personally my ideal setup is that of a dual Access Point + wifi client mode. Some doc to get that working on a pi zero 2 w can be found [here](docs/pi-zero-2w.md).

Else you can have a Access Point / Wifi Client Switcher following the doc [here](docs/ap-switch.md)

## We bundle AutoHotsport-Installer as submodule

```sh
git clone --recurse-submodules git@github.com:wighawag/ethereum-lan-node.git
cd ethereum-lan-node
```

```sh
sudo apt install hostapd dnsmasq
sudo raspi-config # set up localization wifi country (GB for UK)
tar -xvJf AutoHotspot-Installer/AutoHotspot-Setup.tar.xz
cd Autohotspot
sudo ./autohotspot-setup.sh # option 1 + option 7 
sudo reboot
# to force AP mode: sudo ./autohotspot-setup.sh # option 6
```

## Intalling docker

```bash
curl -sSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

You ll need to login and out to have the docker group assigned, then you can test the installation:

```bash
docker ps
```

To execute

```bash
bash start.sh
```

# At boot

```
sudo crontab -e
```

add line:

```
@reboot su <username> -c /home/<username>/ethereum-lan-node/start.sh
```

# NOTE

this was needed at some point to make sure docker get bound to 0.0.0.0

```bash
sysctl -w net.ipv4.ip_forward=1
```

you might want to also add this to crontab

```
sudo crontab -e
```

add line:

```
@reboot sysctl -w net.ipv4.ip_forward=1
```

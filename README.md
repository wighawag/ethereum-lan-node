# ethereum-lan-node
A node for LAN network


# Raspberry PI

We assume you have the networking configured. Personally my ideal setup is that of a dual Access Point + wifi client mode. Some doc to get that working on a pi zero 2 w can be found [here](docs/pi-zero-2w.md).

Else you can have a Access Point / Wifi Client Switcher following the doc [here](docs/ap-switch.md)

## Intalling docker

```
curl -sSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

You ll need to login and out to have the docker group assigned, then you can test the installation:

```
docker ps
```


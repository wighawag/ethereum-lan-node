# ethereum-lan-node
A node for LAN network


# Raspberry PI

We assume you have the networking configured. Personally my ideal setup is that of a dual Access Point + wifi client mode. Some doc to get that working on a pi zero 2 w can be found [here](docs/pi-zero-2w.md).

Else you can have a Access Point / Wifi Client Switcher following the doc [here](docs/ap-switch.md)

## Intalling docker

```bash
curl -sSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

You ll need to login and out to have the docker group assigned, then you can test the installation:

```bash
docker ps
```

## Clone repo

```bash
git clone git@github.com:wighawag/ethereum-lan-node.git
```

## Start

We are using traefik for routing to the various service (currently only rpc.ethereu.local)

Before running docker compose we create a network (instead of relying on docker compose default auto-creation):

```bash
docker network create traefik_net
```

Then you can check its status and what containers are using it via

```bash
docker network inspect traefik_net
```

Note that we have our [traefik.yml](./traefik.yml) configuration file that set some defaults.


```bash
bash start.sh
```
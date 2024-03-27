# ethereum-lan-node

An ethereum node to run on local network, without dependence on the internet.

It includes a blockchain explorer ([blockscout](https://www.blockscout.com/)) with contract verification and wallet connection

We used to run this setup on a Raspberry Pi and we have [doc for that](docs/raspberrypi.md) but due to ipoor availability of ARM docker image for extra feature like blockchain explorer, we recommend using traditional x64 architecture.

We run it on Ubuntu 22.04 but should work anywhere.

We also use it as a dual access point and connected wifi so it can make use of the internet if available

## geth

We run geth in dev mode.

the docker-compose.yml is already setup with the `test test test test test test test test test test test jumk` accounts

Feel free to modifiy to have other accounts

you can run it via 

```
docker compose up
```

## blockscout

we use blockscout as the blockchain explorer

We include it as a submodule


to run it, you have to have geth running first

```
cd blockscout/docker-compose
docker compose -f geth.yml up
```


## have it run on boot

```
sudo ./install.sh
```

this will copy the files in the [install folder](./install). This assumes you are using systemd.
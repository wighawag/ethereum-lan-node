#!/bin/bash
MY_PATH="$(dirname -- "${BASH_SOURCE[0]}")"
echo "cd $MY_PATH ..."
cd $MY_PATH

docker compose down
cd blockscout/docker-compose
docker compose -f geth.yml down

if [[ "$1" == "and-delete" ]]
then
  cd ../..
  docker volume rm ethereum-lan-node_geth-data
  sudo rm -Rf ./services/blockscout-db-data/
  sudo rm -Rf ./services/logs/
  sudo rm -Rf ./services/redis-data/
  sudo rm -Rf ./services/stats-db-data/
fi


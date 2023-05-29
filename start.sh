if [[ "$1" == "with-explorer" ]]
then
docker compose -f docker-compose.yml -f docker-compose.blockscout.yml up
else
docker compose up
fi

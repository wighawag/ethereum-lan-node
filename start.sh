if [[ "$1" == "with-explorer" ]]
then
echo "currently not supported"
exit 1
docker compose -f docker-compose.yml -f docker-compose.blockscout.yml up -d
else
if [ -z "$1" ]
then
docker compose up -d
else
echo "do not accept any argument"
exit 1
fi
fi

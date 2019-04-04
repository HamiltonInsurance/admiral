#!/bin/bash

echo "WARNING: this will delete all dangling containers/volumes/images/etc."
if [ "$1" == "-r" ]; then
    echo "         and then restart docker."
fi
echo "Press return to continue or Ctrl-c to break"
read x
docker volume ls -qf dangling=true | xargs -r docker volume rm
#docker network rm $(docker network ls | grep "bridge" | awk '/ / { print $1 }')
docker rmi $(docker images --filter "dangling=true" -q --no-trunc)
docker rmi $(docker images | grep "none" | awk '/ / { print $3 }')
docker rm $(docker ps -qa --no-trunc --filter "status=exited")
if [ "$1" == "-r" ]; then
    echo "restarting docker..."
    sudo service docker restart
fi    

#!/bin/bash

# A script for updating a running python container.

# Set up parameters
APP=$0
SRV=
WORKDIR=$(mktemp -d)
GIT_USER=$(whoami)

if ! valenv GIT_HOST MANIFEST_REPO; then exit 1 fi

function die
{
    echo $1
    exit 1
}

function fin
{
    echo $1
    exit 0
}

function usage
{
    echo
    echo "Usage: $APP -s SERVICE [-d DIR] [-t STACK] [-u user] [-f DOCKERFILE] [-b BRANCH]"
    echo "A shell script for developing services."
    echo
    echo " -s, --srv SRV               Service to develop."
    echo " -u, --user NAME             Name of the git user (default: \$(whoami))"
    echo " -b, --branch BRANCH         Name of the branch to use (default: HEAD)"
}


while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -h|--help)
            usage
            exit
            ;;
        -s|--srv)
            SRV="$2"
            shift # past argument            
            ;;
        -u|--user)
            GIT_USER="$2"
            shift # past argument            
            ;;
        -b|--branch)
            BRANCH="$2"
            shift # past argument            
            ;;
        *)
            usage
            die "unknown argument: $1"
            ;;
    esac
    shift # past argument or value
done

if [ -z "$SRV" ]; then
    die "must specify service to develop"
fi

pushd ${WORKDIR} > /dev/null || die "unable to use work dir: ${WORKDIR}"
echo "Cloning Manifest"
git clone ${GIT_HOST}/${MANIFEST_REPO}.git > /dev/null 2>&1|| die "unable to clone current manifest"
SRV_REPO=$(cat manifest/services | jq -r ".services.$SRV.git")
REPO_NAME=$(echo $SRV_REPO | cut -d/ -f2)
echo "Cloning Service to Update"
if [ ! -z $BRANCH ]; then
	git clone ${GIT_HOST}/~${GIT_USER}/${REPO_NAME}.git --branch $BRANCH --depth=1 > /dev/null 2>&1 || die "unable to clone $SRV"
else 
	git clone ${GIT_HOST}/~${GIT_USER}/${REPO_NAME}.git --depth=1 > /dev/null 2>&1 || die "unable to clone $SRV"
fi

LOCAL_REPO=${WORKDIR}/${REPO_NAME}
popd > /dev/null

CONTAINERS=$(fleet ls | grep "Up " | grep "_$SRV\." | awk '{print $1}' | xargs echo) 
for CONTAINER in $CONTAINERS; do
	echo "Updating $CONTAINER"
	echo docker cp $LOCAL_REPO/ $CONTAINER:/application/
	docker cp $LOCAL_REPO/. $CONTAINER:/application/
done

if [[ "$WORKDIR" =~ ^/tmp/.* ]]; then
	echo "Deleting $WORKDIR"
	rm -rf "$WORKDIR"
fi 

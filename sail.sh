#!/bin/bash

# A script for starting, or restarting services

# Set up parameters
APP=$0
SRV=
WORKDIR=
STACK_NAME=
GIT_USER=$(whoami)
REPLACE_FOLDER=
DEV_MODE=
TAIL_LOGS="FALSE"
VERBOSE="FALSE"
MANIFEST_NAME=
MANIFEST_BRANCH=
MANIFEST_FROM_LOCAL=
PROXY_BRANCH=
EXPOSE_SERVICES=
REMOTE_SERVICES=
CONFIG_OVERRIDE_FOLDER=${HOME}/config_override
CONFIG_FOLDER=${HOME}/config

if ! valenv GIT_HOST CONFIG_REPO; then exit 1 fi

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
    echo "Usage: $APP -s SERVICE [-d DIR] [-t STACK] [-u user] [-r FOLDER] [-b BRANCH] [-l]"
    echo "A shell script for developing services."
    echo
    echo " -d, --dir DIR                       Directory in which to place all code"
    echo " -s, --srv SRV                       Service to develop. Can be a comma-separated list (in which case only the first is enabled for remote access)."
    echo " -t, --stack STACK                   Name of the stack to launch (default: bootstrap_STACK)"
    echo " -u, --user NAME                     Name of the git user (default: \$(whoami))"
    echo " -r, --replace-folder FOLDER         The contents of this folder will replace any similarly named files"
    echo " -c, --config-folder FOLDER          The location of the config"
    echo " -o, --config-override-folder FOLDER Thelocation of the config overrides"
    echo " -b, --branch BRANCH                 Name of the branch to use (default: HEAD)"
    echo " -l, --tail-logs                     Tail the logs when done"
    echo " -m, --manifest-name                 Manifest name (default: services)"
    echo " --manifest-branch                   Manifest branch (default: release/1.0)"
    echo " --manifest-from-local               Use the manifest from local repo"
    echo " --proxy-branch                      Optional override of branch to use for haproxy"
    echo " --expose-services                   Comma-separated list of service:port to expose outside the swarm"
    echo " --remote-services                   Optional comma-separated list of services to which to apply the folder replacement. If none, use the services list."
    echo " -v, --verbose                       Verbose mode for admiral"
}

cd ~

while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -h|--help)
            usage
            exit
            ;;
        -d|--dir)
            WORKDIR="$2"
            shift # past argument
            ;;
        -s|--srv)
            SRV="$2"
            shift # past argument            
            ;;
        -t|--stack)
            STACK_NAME="$2"
            shift # past argument            
            ;;
        -u|--user)
            GIT_USER="$2"
            shift # past argument            
            ;;
        -r|--replace-folder)
            REPLACE_FOLDER="$2"
            shift # past argument            
            ;;
        -c|--config-folder)
            CONFIG_FOLDER="$2"
            shift # past argument            
            ;;
        -o|--config-override-folder)
            CONFIG_OVERRIDE_FOLDER="$2"
            shift # past argument            
            ;;
        -b|--branch)
            BRANCH="$2"
            shift # past argument            
            ;;
        -m|--manifest-name)
            MANIFEST_NAME="$2"
            shift # past argument
            ;;
        --manifest-branch)
            MANIFEST_BRANCH="$2"
            shift # past argument
            ;;
	--manifest-from-local)
	    MANIFEST_FROM_LOCAL=1
	    ;;
        --proxy-branch)
            PROXY_BRANCH="$2"
            shift # past argument
            ;;
        --expose-services)
            EXPOSE_SERVICES="$2"
            shift # past argument
	    ;;
        --remote-services)
            REMOTE_SERVICES="$2"
            shift # past argument
            ;;
        -l|--tail-logs)
            TAIL_LOGS="TRUE"
            ;;
        -v|--verbose)
            VERBOSE="TRUE"
            ;;
        --dev)
            DEV_MODE="TRUE"
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

SRV_LIST=(${SRV//,/ })
LOCAL_SRV=${SRV_LIST[0]}

# Devise default working directory

if [ -z "$WORKDIR" ]; then

    if [ -e ~/src ]; then
        WORKDIR="$HOME/src/${LOCAL_SRV}"
    else 
        WORKDIR="$HOME/dev/${LOCAL_SRV}"
    fi

    if [ ! -z "$BRANCH" ]; then
        WORKDIR=$WORKDIR/$BRANCH
    fi

fi

if [ -z "${STACK_NAME}" ]; then
    STACK_NAME="bootstrap_${LOCAL_SRV}"
fi

if [ -z "${MANIFEST_NAME}" ]; then
    MANIFEST_NAME="services.${LOCAL_SRV}"
fi

if [ -z "${MANIFEST_BRANCH}" ]; then
    MANIFEST_BRANCH="release/1.0"
fi

if [ -e ${WORKDIR} ]; then
    rm -rf "${WORKDIR}"
fi 

BOOTSTRAP_ARGS="-d ${WORKDIR} -s $SRV -t $STACK_NAME -u $GIT_USER"
if [ ! -z $BRANCH ]; then
    BOOTSTRAP_ARGS="$BOOTSTRAP_ARGS -b $BRANCH"
fi
if [ ! -z $MANIFEST_BRANCH ]; then
    BOOTSTRAP_ARGS="$BOOTSTRAP_ARGS --manifest-branch $MANIFEST_BRANCH"
fi
if [ ! -z $MANIFEST_FROM_LOCAL ]; then
    BOOTSTRAP_ARGS="$BOOTSTRAP_ARGS --manifest-from-local"
fi
if [ ! -z $MANIFEST_NAME ]; then
    BOOTSTRAP_ARGS="$BOOTSTRAP_ARGS --manifest-name $MANIFEST_NAME"
fi
if [ ! -z $PROXY_BRANCH ]; then
    BOOTSTRAP_ARGS="$BOOTSTRAP_ARGS --proxy-branch $PROXY_BRANCH"
fi
if [ ! -z $EXPOSE_SERVICES ]; then
    BOOTSTRAP_ARGS="$BOOTSTRAP_ARGS --expose-services $EXPOSE_SERVICES"
fi
bootstrap $BOOTSTRAP_ARGS || die "Bootstrap failed"

if [ ! -e ${WORKDIR}/manifest/${MANIFEST_NAME} ]; then
    die "${MANIFEST_NAME} doesn't exist"
fi

if [ -z $REMOTE_SERVICES ]; then
    REMOTE_SERVICES=${SRV}
fi
for REMOTE_ACCESS_SERVICE in ${REMOTE_SERVICES//,/ }; do

    LOCAL_REPO=$(cat ${WORKDIR}/manifest/${MANIFEST_NAME} | jq ".services.${REMOTE_ACCESS_SERVICE}.dir" | tr -d '"')

    pushd ${LOCAL_REPO} > /dev/null 2>&1

    if [ ! -z "${REPLACE_FOLDER}" ]; then
        find ${REPLACE_FOLDER} -type d | while read SUB_FOLDER; do
            CREATE_FOLDER=$(echo ${SUB_FOLDER} | sed "s/^${REPLACE_FOLDER}\/*//")
            if [ ! -z "${CREATE_FOLDER}" ]; then
                mkdir -p ${CREATE_FOLDER}
            fi
        done

        find ${REPLACE_FOLDER} -type f | while read REPLACE_FILE_WITH; do
            REPLACE_FILE=$(echo ${REPLACE_FILE_WITH} | sed "s/^${REPLACE_FOLDER}\/*//")
            mv ${REPLACE_FILE_WITH} ${REPLACE_FILE}
        done
    fi
done

if [ -d "${CONFIG_FOLDER}" ] && [ -d "${CONFIG_OVERRIDE_FOLDER}" ] && [ ! -z "${CONFIG_FOLDER}" ] && [ ! -z "${CONFIG_OVERRIDE_FOLDER}" ]; then
    rm -rf "${CONFIG_FOLDER}"/* 2>&1 
    rm -rf "${CONFIG_FOLDER}"/.* 2>&1
    git clone ${GIT_REPO}/${CONFIG_REPO}.git ${CONFIG_FOLDER}
    cp ${CONFIG_OVERRIDE_FOLDER}/* ${CONFIG_FOLDER}/ 
fi

ADMIRAL_ARGS="--remote-access ${REMOTE_SERVICES}"

if [ "$VERBOSE" == "TRUE" ]; then
    ADMIRAL_ARGS="${ADMIRAL_ARGS} -v"
fi
if [ "$DEV_MODE" == "TRUE" ]; then
    ADMIRAL_ARGS="${ADMIRAL_ARGS} --dev"
fi

admiral ${ADMIRAL_ARGS} ${WORKDIR}/manifest/${MANIFEST_NAME} ${STACK_NAME}
echo admiral ${ADMIRAL_ARGS} ${WORKDIR}/manifest/${MANIFEST_NAME} ${STACK_NAME}

if [ $TAIL_LOGS == "TRUE" ]; then
    fleet logs 
fi

popd > /dev/null 2>&1

cd ${LOCAL_REPO}

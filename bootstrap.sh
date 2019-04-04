#!/bin/bash

# A script for setting up a dev environment of one or more services.

if ! valenv MANIFEST_REPO CONFIG_DIR GIT_HOST; then exit 1 fi

# Set up parameters
APP=$0
SRV=
WORKDIR=
STACK_NAME=
GIT_USER=$(whoami)
DOCKERFILE=
RUN="FALSE"
DEFAULT_MANIFEST_NAME="services"
MANIFEST_NAME=
MANIFEST_BRANCH=
MANIFEST_FROM_LOCAL=
PROXY_BRANCH=
EXPOSE_SERVICES=

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
    echo " -d, --dir DIR               Directory in which to place all code"
    echo " -s, --srv SRV               Comma-separated list of services for which to use local copies"
    echo " -t, --stack STACK           Name of the stack to launch (default: bootstrap_STACK)"
    echo " -u, --user NAME             Name of the git user (default: \$(whoami))"
    echo " -f, --dockerfile DOCKERFILE The dockerfile that you will be using (default: content of services file)"
    echo " -b, --branch BRANCH         Name of the branch to use (default: HEAD)"
    echo " --manifest-branch BRANCH    Name of the branch to use for manifests (default: release/1.0)"
    echo " --manifest-from-local       Use the manifest from local repo"
    echo " -m, --manifest-name BRANCH  Manifest name (default: services)"
    echo " --proxy-branch              Optional override of branch to use for haproxy"
    echo " --expose-services           Comma-separated list of service:port to expose outside the swarm"
    echo " -r, --run                   Start up the services at the end"
}

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
        -f|--dockerfile)
            DOCKERFILE="$2"
            shift # past argument            
            ;;
        -b|--branch)
            BRANCH="$2"
            shift # past argument            
            ;;
        --manifest-branch)
            MANIFEST_BRANCH="$2"
            shift # past argument
            ;;
	--manifest-from-local)
	    MANIFEST_FROM_LOCAL=1
	    ;;
        -m|--manifest-name)
            MANIFEST_NAME="$2"
            shift # past argument
            ;;
        -r|--run)
            RUN="TRUE"
            ;;
        --proxy-branch)
            PROXY_BRANCH="$2"
            shift # past argument
            ;;
        --expose-services)
            EXPOSE_SERVICES="$2"
            shift # past argument
            ;;	    
        *)
            usage
            die "unknown argument: $1"
            ;;
    esac
    shift # past argument or value
done

if [ -z "${GIT_HOST}" ]; then
	die "\${GIT_HOST} not set"
fi

if [ -z "$SRV" ]; then
    die "must specify service to develop"
fi

# Devise default working directory

if [ -z "$WORKDIR" ]; then

    if [ -e $HOME/src ]; then
        WORKDIR="$HOME/src/$SRV"
    else 
        WORKDIR="$HOME/dev/$SRV"
    fi

    if [ ! -z "$BRANCH" ]; then
        WORKDIR=$WORKDIR/$BRANCH
    fi

fi

if [ -z "${STACK_NAME}" ]; then
    STACK_NAME="bootstrap_$SRV"
fi

if [ -z "${MANIFEST_NAME}" ]; then
    MANIFEST_NAME="services.${SRV}"
fi

if [ -z "${MANIFEST_BRANCH}" ]; then
    MANIFEST_BRANCH="release/1.0"
fi

if [ -e ${WORKDIR} ]; then
    die "$WORKDIR already set up"
fi 

function haproxy_services_replacement
{
    local FILENAME=$1
    local SERVICES=$2

    cat $FILENAME > $FILENAME.new

    local SERVICE=
    for SERVICE in ${SERVICES//,/ }
    do
        local SERVICE_SPLIT=(${SERVICE//:/ })
        local SERVICE_NAME=${SERVICE_SPLIT[0]}
        local SERVICE_PORT=${SERVICE_SPLIT[1]}
        cat >> $FILENAME.new <<-EOF

frontend service_frontend_${SERVICE_NAME}
   bind *:${SERVICE_PORT} ssl crt ${CONFIG_DIR}/cert
   mode http
   default_backend service_backend_${SERVICE_NAME}

backend service_backend_${SERVICE_NAME}
   balance leastconn
   option forwardfor
   http-request set-header X-Forwarded-Port %[dst_port]
   http-request add-header X-Forwarded-Proto https if { ssl_fc }
   server ${SERVICE_NAME} ${SERVICE_NAME}:5000 check init-addr none resolvers docker resolve-prefer ipv4
EOF

    done

    mv ${FILENAME}.new ${FILENAME}
}

function docker_ports_replacement
{
    local FILENAME=$1
    local SERVICES=$2

    cat ${FILENAME} > ${FILENAME}.new

    local SERVICE=
    for SERVICE in ${SERVICES//,/ }
    do
        local SERVICE_SPLIT=(${SERVICE//:/ })
        local SERVICE_NAME=${SERVICE_SPLIT[0]}
        local SERVICE_PORT=${SERVICE_SPLIT[1]}
        printf "      - \"%s:%s\"\n" $SERVICE_PORT $SERVICE_PORT >> ${FILENAME}.new
    done

    mv ${FILENAME}.new ${FILENAME}
}

function use_local_service
{
    local SRV=$1

    echo "Preparing local service ${SRV}..."

    WORKDIR_SRV=${WORKDIR}/${SRV}
    mkdir -p ${WORKDIR_SRV} || die "unable to make service work dir: ${WORKDIR_SRV}"

    SRV_REPO=$(cat ${WORKDIR}/manifest/${MANIFEST_NAME} | jq -r ".services.$SRV.git")
    if [ -z "$SRV_REPO" ] || [ "$SRV_REPO" == "null" ]; then
        SRV_REPO="~${GIT_USER}/${SRV}"
    fi

    REPO_NAME=$(echo $SRV_REPO | cut -d/ -f2)
    LOCAL_REPO=${WORKDIR_SRV}/${REPO_NAME}

    # modify service to use local dir and remove remote (git)

    cat ${WORKDIR}/manifest/${MANIFEST_NAME} | jq -r ".services.$SRV.dir = \"${LOCAL_REPO}\" | del(.services.$SRV.git) | del (.services.$SRV.tag)" > ${WORKDIR}/manifest/${MANIFEST_NAME}.new || die "unable to modify local services file"
    mv ${WORKDIR}/manifest/${MANIFEST_NAME}.new ${WORKDIR}/manifest/${MANIFEST_NAME} || die "unable to replace local services file"

    # modify services to use custom docker file

    if [ ! -z "$DOCKERFILE" ]; then
        cat ${WORKDIR}/manifest/${MANIFEST_NAME} | jq -r ".services.$SRV.dockerfile = \"${DOCKERFILE}\"" > ${WORKDIR}/manifest/${MANIFEST_NAME}.new || die "unable to modify local services file"
        mv ${WORKDIR}/manifest/${MANIFEST_NAME}.new ${WORKDIR}/manifest/${MANIFEST_NAME} || die "unable to replace local services file"
    fi

    pushd ${WORKDIR_SRV} > /dev/null
    git clone --recurse-submodules ${GIT_HOST}/${SRV_REPO}.git > /dev/null 2>&1 || die "unable to clone ${GIT_HOST}/${SRV_REPO}"
    popd > /dev/null

    pushd ${LOCAL_REPO} > /dev/null

    git remote add upstream ${GIT_HOST}/${SRV_REPO}.git
    git remote set-url origin ${GIT_HOST}/~${GIT_USER}/${REPO_NAME}.git
    git fetch > /dev/null 2>&1

    if [ ! -z "$BRANCH" ]; then
        if [[ $(git branch | grep "^\*\? $BRANCH$") ]]; then
            git checkout $BRANCH || die "Changing branch failed"
        elif [[ $(git ls-remote --heads origin $BRANCH) ]]; then
            git checkout --track origin/$BRANCH || die "Changing branch failed"
        else
            die "Can't find branch ${BRANCH} of ${GIT_HOST}/${SRV_REPO}"
        fi
    fi

    popd > /dev/null
}


echo "Bootstrapping into $WORKDIR and launching $STACK_NAME..."
mkdir -p ${WORKDIR} || die "unable to make work dir: ${WORKDIR}"

pushd ${WORKDIR} > /dev/null || die "unable to use work dir: ${WORKDIR}"

if [ ! -z "${MANIFEST_FROM_LOCAL}" ]; then
    MANIFEST_REPO=~${GIT_USER}/manifest
fi
git clone ${GIT_HOST}/${MANIFEST_REPO}.git || die "unable to clone current manifest"

pushd ${WORKDIR}/manifest > /dev/null
if [ ! -z "$MANIFEST_BRANCH" ]; then
    if [[ $(git branch | grep "^\*\? $MANIFEST_BRANCH$") ]]; then
        git checkout $MANIFEST_BRANCH || die "Changing manifest branch failed"
    elif [[ $(git ls-remote --heads origin $MANIFEST_BRANCH) ]]; then
        git checkout --track origin/$MANIFEST_BRANCH || die "Changing manifest branch failed"
    else
        die "Changing manifest branch failed"
    fi
fi
if [ ! -e "${MANIFEST_NAME}" ]; then
    cp ${DEFAULT_MANIFEST_NAME} ${MANIFEST_NAME}
fi
popd > /dev/null

if [ ! -z "$PROXY_BRANCH" ] || [ ! -z "$EXPOSE_SERVICES" ]; then
    PROXY_REPO="util/srv_proxy"
    if [ ! -z "$PROXY_BRANCH" ]; then
        PROXY_REPO="~${GIT_USER}/srv_proxy"
    fi

    if [ -z "$PROXY_BRANCH" ]; then
        PROXY_BRANCH=release/1.0
    fi
    echo "Using local proxy: $PROXY_BRANCH ..."
    
    git clone ${GIT_HOST}/${PROXY_REPO}.git || die "unable to clone current srv_proxy"
    git remote set-url origin ${GIT_HOST}/${PROXY_REPO}.git
    git fetch > /dev/null 2>&1

    pushd ${WORKDIR}/srv_proxy > /dev/null
        if [[ $(git branch | grep "^\*\? $PROXY_BRANCH$") ]]; then
            git checkout $PROXY_BRANCH || die "Changing proxy branch failed"
        elif [[ $(git ls-remote --heads origin $PROXY_BRANCH) ]]; then
            git checkout --track origin/$PROXY_BRANCH || die "Changing proxy branch failed"
        else
            die "Changing proxy branch failed"
        fi

	if [ ! -z "$EXPOSE_SERVICES" ]; then
            echo "Exposing services: $EXPOSE_SERVICES ..."
            haproxy_services_replacement haproxy.cfg $EXPOSE_SERVICES || die "unable to modify HAProxy config"
        fi

    popd > /dev/null

    # update srv_proxy to use the local copy
    PROXY_SERVICE_NAME=proxy
    cat ${WORKDIR}/manifest/${MANIFEST_NAME} | jq -r ".services.${PROXY_SERVICE_NAME}.dir = \"${WORKDIR}/srv_proxy\" | del(.services.${PROXY_SERVICE_NAME}.git) | del (.services.${PROXY_SERVICE_NAME}.tag)" > ${WORKDIR}/manifest/${MANIFEST_NAME}.new || die "unable to modify local services file when editing proxy"
    mv ${WORKDIR}/manifest/${MANIFEST_NAME}.new ${WORKDIR}/manifest/${MANIFEST_NAME} || die "unable to replace local services file when editing proxy"

    if [ ! -z "$EXPOSE_SERVICES" ]; then
        echo "Exposing services ports externally: $EXPOSE_SERVICES ..."
        docker_ports_replacement manifest/compose.ports $EXPOSE_SERVICES || die "unable to modify compose ports"
    fi
fi	

for LOCAL_SERVICE in ${SRV//,/ }
do
    use_local_service ${LOCAL_SERVICE}
done

popd > /dev/null

if [ $RUN == "TRUE" ]; then
    admiral ${WORKDIR}/manifest/${MANIFEST_NAME} ${STACK_NAME}
    echo admiral ${WORKDIR}/manifest/${MANIFEST_NAME} ${STACK_NAME}
fi


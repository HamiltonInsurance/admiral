#!/bin/bash

# A script for setting up a dockerised instance of HA Proxy which forwards to a number of other instances.

# Set up parameters

APP=$0
HOSTNAME=$(hostname)
DOCKERFILE=Dockerfile
IMAGE_NAME=
FIX=
AUDIT_TAG=
REPO=
WORK=
STACK_LABEL=general
CACHE_DIR=/tmp
FOLLOW=
SWARM_HOST=
SWARM_TOKEN=
LEADER="yes"

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

if ! valenv REGISTRY CONFIG_DIR; then exit 1; fi

function usage
{
    echo
    echo "Usage: $APP COMMAND"
    echo "A shell script for navigating a fleet of services"
    echo
    echo "Possible commands:"
    echo
    echo " board  - login to a runnning image"
    echo " build  - create a binary image from a directory of source code"
    echo " deploy - create/update a named group of services"
    echo " logs   - show service logs"
    echo " ls     - list information about services"
    echo " sink   - completely detroy a named group of services"
    echo
}

function usage_deploy {
    echo
    echo "Usage: $APP deploy PREFIX [OPTIONAL]"
    echo "Deploy your fleet, Admiral"
    echo
    echo " -w, --work-file FILE      A YAML file with orchestration instructions"
    echo
    echo "Optional:"
    echo " -h, --help                This help message"
    echo " -l, --label LABEL         A label for the stack (default: $STACK_LABEL)"
    echo " -t, --token TOKEN         Swarm token to join"
    echo " -m, --manager HOST        Manager host to join"
    echo
}

function usage_logs {
    echo
    echo "Usage: $APP logs"
    echo "Show captain's logs"
    echo
}

function usage_sink {
    echo
    echo "Usage: $APP sink PREFIX"
    echo "Sink your fleet, Admiral"
    echo
    echo
}

function usage_board {
    echo
    echo "Usage: $APP board PREFIX"
    echo "Board your fleet, Admiral"
    echo
    echo
}

function usage_build {
    echo
    echo "Usage: $APP build DIR [OPTIONAL]"
    echo "Build a service image"
    echo
    echo " -n, --image-name NAME Base name of the image"
    echo " -d, --dockerfile NAME Name of the dockerfile"
    echo " -c, --cache DIR       Cache directory"
    echo
    echo "Optional:"
    echo " -s, --suffix          Image name suffix (e.g., tag)"
    echo " -h, --help            This help message"
    echo
}

while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -h|--help)
            if [ -z $CMD ]; then
                usage
            else
                case $CMD in
                    build)
                        usage_build
                        ;;
                    deploy)
                        usage_deploy
                        ;;
                    sink)
                        usage_sink
                        ;;
                    logs)
                        usage_logs
                        ;;
                    board|shell)
                        usage_board
                        ;;
                esac
            fi
            exit
            ;;
        -a|--audit-tag)
            AUDIT_TAG="$2"
            shift # past argument
            ;;
        -n|--image-name)
            IMAGE_NAME="$2"
            shift # past argument
            ;;
        -w|--work-dir|--work-file)
            WORK="$2"
            shift # past argument
            ;;
        -l|--label)
            STACK_LABEL="$2"
            shift # past argument
            ;;
        -t|--token)
            SWARM_TOKEN="$2"
            shift # past argument
            ;;
        -m|--manager)
            SWARM_HOST="$2"
            LEADER="no"
            shift # past argument
            ;;
        -x|--prefix)
            FIX="$2"
            shift # past argument
            ;;
        -s|--suffix)
            FIX="$2"
            shift # past argument
            ;;
        -H|--hostname)
            HOSTNAME="$2"
            shift # past argument
            ;;
        -d|--dockerfile)
            DOCKERFILE="$2"
            shift # past argument
            ;;
        -c|--cache)
            CACHE_DIR="$2"
            shift # past argument
            ;;
        -f|--follow)
            FOLLOW="-f"
            ;;
        build)
            CMD="$key"
            WORK="$2"
            shift # past argument
            ;;
        ls|list)
            CMD="$key"
            WORK="$2"
            shift # past argument
            ;;
        logs)
            CMD="$key"
            ;;
        deploy|sink|board|containers)
            CMD="$key"
            if [[ "$2" = -* ]]; then
                if [ ! "$CMD" == "build" ] || [ ! "$CMD" == "ls"]; then
                    usage
                    die "A prefix must be provided"
                fi
            else
                FIX="$2"
                shift # past argument
            fi
            ;;
        *)
            usage
            die "Unknown option!"
            ;;
    esac
    shift # past argument or value
done

if [ -z "$CMD" ]; then
    usage
    die "Your orders please!"
fi

function containers
{
    $0 ls | grep ${FIX} | grep "Running " | awk '{print $3}'
}

function logs
{
    tail -f /var/log/docker_combined.log
}

function build
{
    if [ ! -f "${WORK}/${DOCKERFILE}" ]; then
        die "Dockerfile does not exist: ${WORK}/${DOCKERFILE}"
    fi
    if [ -z "$IMAGE_NAME" ]; then
        usage_build
        die "Image name required (-n)"
    fi

    SCRATCH_DIR=`mktemp -p ${CACHE_DIR} -d`
    trap "rm -rf ${SCRATCH_DIR}" EXIT

    if [ -z "$FIX" ]; then
        FIX=$(git --git-dir ${WORK}/.git rev-parse --short HEAD)
    fi
    IMAGE_NAME="${IMAGE_NAME}"
    IMAGE_VER="${FIX}"
    IMAGE_NAME_VER="${IMAGE_NAME}:${IMAGE_VER}"
    echo "Image: ${IMAGE_NAME_VER}"

    rsync -av ${WORK}/ ${SCRATCH_DIR}/ > /dev/null

    local FORCE_BUILD="no"
    local NEW_BUILD="no"

    # find local registry
    local REG_AVAILABLE="no"
    if ! nslookup ${REGISTRY} > /dev/null 2>&1; then
        echo "WARNING: ${REGISTRY} does not exist!"
    elif ping -c 1 ${REGISTRY} > /dev/null 2>&1; then
        if curl -s https://${REGISTRY}/v2/_catalog > /dev/null 2>&1; then
            REG_AVAILABLE="yes"
        fi
    fi
    echo "Registry available: ${REG_AVAILABLE}"

    # use default dockerfile name at the root in all cases
    cp ${WORK}/${DOCKERFILE} ${SCRATCH_DIR}/Dockerfile

    if docker image ls --format "{{.Repository}}:{{.Tag}}" | grep "^$IMAGE_NAME_VER" > /dev/null; then
        echo "Reusing local image: ${IMAGE_NAME_VER}"
    else
        if [ "${REG_AVAILABLE}" == "yes" ]; then
            echo "Checking registry for image: ${IMAGE_NAME_VER}"
            # check if image available on the registry
            local REG_IMAGE="${REGISTRY}/${IMAGE_NAME}"
            local REMOTE_MISSING=$(curl -s https://${REGISTRY}/v2/${IMAGE_NAME}/tags/list | jq -r 'has("errors")')
            if [ "${REMOTE_MISSING}" == "false" ]; then
                local VER_FOUND="false"
                for v in $(curl -s https://${REGISTRY}/v2/${IMAGE_NAME}/tags/list | jq -r ".tags[] | select(.|contains(\"${IMAGE_VER}\"))"); do
                    echo "Checking ${v} with ${IMAGE_VER}..."
                    if [ "${v}" == "${IMAGE_VER}" ]; then
                        echo "Pulling ${REG_IMAGE}:${IMAGE_VER}"
                        docker pull $REG_IMAGE:${IMAGE_VER} || die "unable to pull image from registry: $REG_IMAGE:${IMAGE_VER}"
                        docker tag $REG_IMAGE:${IMAGE_VER} $IMAGE_NAME:${IMAGE_VER} || die "unable to tag $REG_IMAGE as $IMAGE_NAME"
                        VER_FOUND="true"
                        break
                    fi
                done
                if [ "${VER_FOUND}" == "false" ]; then
                    echo "No remote tag found, force building ${IMAGE_NAME_VER}"
                    FORCE_BUILD="yes"
                fi
            else
                # a build is necessary at this point
                echo "No remote image found, force building ${IMAGE_NAME}"
                FORCE_BUILD="yes"
            fi
        else
            FORCE_BUILD="yes"
        fi

        if [ "${REG_AVAILABLE}" == "yes" ] && [ "${FORCE_BUILD}" == "yes" ]; then
            # check if FROM available on the repository
            local ORIGFROMIMAGE=$(cat ${SCRATCH_DIR}/Dockerfile | grep FROM | head -n 1 | awk '{print $2}' | tr -d '\15\32')
            local ORIGFROMIMAGE_ROOT=$ORIGFROMIMAGE
            local ORIGFROMIMAGE_VER="latest"
            if echo ${ORIGFROMIMAGE} | grep -q ":"; then
                ORIGFROMIMAGE_ROOT=$(echo $ORIGFROMIMAGE | cut -d: -f1)
                ORIGFROMIMAGE_VER=$(echo $ORIGFROMIMAGE | cut -d: -f2)
            fi

            local FROM_IMAGE="${REGISTRY}/${ORIGFROMIMAGE}"
            REMOTE_MISSING=$(curl -s https://${REGISTRY}/v2/${ORIGFROMIMAGE_ROOT}/tags/list | jq -r 'has("errors")')
            if [ "${REMOTE_MISSING}" == "false" ]; then
                # check that version is there
                local VER=$(curl -s https://${REGISTRY}/v2/${ORIGFROMIMAGE_ROOT}/tags/list | jq -r ".tags[] | select(.|contains(\"${ORIGFROMIMAGE_VER}\"))")
                if [ "${VER}" != "${ORIGFROMIMAGE_VER}" ]; then
                    REMOTE_MISSING="true"
                fi
            fi
            if [ "${REMOTE_MISSING}" == "true" ]; then
                # the FROM image is missing from our registry
                # try to pull from docker and push to our registry
                echo "Remote is missing ${FROM_IMAGE}, pulling from docker"
                docker pull ${ORIGFROMIMAGE} || die "unable to pull original image from docker: $ORIGFROMIMAGE"
                echo "Tagging ${FROM_IMAGE}"
                docker tag ${ORIGFROMIMAGE} ${FROM_IMAGE} || die "unable to tag original image: ${ORIGFROMIMAGE} as ${FROM_IMAGE}"
                echo "Pushing ${FROM_IMAGE}"
                docker push ${FROM_IMAGE} || die "unable to push ${FROM_IMAGE}"
            fi

            # replace FROM with our registry version of the image
            sed -i -r "0,/^FROM/{s|^FROM\s+\S+|FROM ${FROM_IMAGE}|}" ${SCRATCH_DIR}/Dockerfile
        fi

        if [ "${FORCE_BUILD}" == "yes" ]; then
            # build
            echo "Building ${IMAGE_NAME_VER} from ${SCRATCH_DIR}..."
            docker build -t "${IMAGE_NAME_VER}" "${SCRATCH_DIR}" || die "unable to build ${IMAGE_NAME_VER}"
            NEW_BUILD="yes"
        fi
    fi
    errorCode=$?
    if [ $errorCode -gt 0 ]; then
        die "Failed to build. Error code $errorCode; stopping build."
    fi
    if [ "${REG_AVAILABLE}" == "yes" ] && [ "${NEW_BUILD}" == "yes" ]; then
        # if this is an actual tagged build, and not just a random local build
        if ! [[ $IMAGE_VER =~ local* ]]; then
            # push the tagged image
            local TAGGED_IMAGE_NAME="${REGISTRY}/${IMAGE_NAME_VER}"
            docker tag ${IMAGE_NAME_VER} ${TAGGED_IMAGE_NAME}
            docker push ${TAGGED_IMAGE_NAME}
            if [ ! -z "${AUDIT_TAG}" ]; then
                # give it an extra audit tag (this is usually going to be the git SHA of the tag)
                TAGGED_IMAGE_NAME="${REGISTRY}/${IMAGE_NAME}:${IMAGE_VER}_${AUDIT_TAG}"
                docker tag ${IMAGE_NAME_VER} ${TAGGED_IMAGE_NAME}
                docker push ${TAGGED_IMAGE_NAME}
            fi
        fi
    fi
}

function deploy
{
    if [ -z $FIX ]; then
        usage_deploy
        die "A prefix must be provided to deploy (-x)"
    fi

    if [ -z $WORK ]; then
        usage_deploy
        die "A stack file must be provided to deploy (-w)"
    fi
    if [ ! -e ${CONFIG_DIR} ]; then
        die "Config not found: ${CONFIG_DIR}"
    fi

    # swarm
    if [ "${LEADER}" == "yes" ]; then
        local INT_IP=$(ip route get 8.8.8.8 | awk '{print $NF; exit}') # internal IP
        docker swarm init --advertise-addr $INT_IP > /dev/null 2>&1
        docker node update --label-add ${STACK_LABEL}=true $(hostname)

        COMPOSE_DIR=`mktemp -d`

        # add compose file
        cp $WORK $COMPOSE_DIR/compose.yml

        # the actual deploy, we pushd here in order to make all paths relative
        pushd $COMPOSE_DIR/ > /dev/null
        cat "${COMPOSE_DIR}/compose.yml"
        docker stack deploy -c "${COMPOSE_DIR}/compose.yml" "${FIX}" || die "failed to deploy ${FIX}"
        popd > /dev/null

        rm -rf ${COMPOSE_DIR}
    else
        if [ -z "${SWARM_TOKEN}" ] || [ -z "${SWARM_HOST}" ]; then
            die "Swarm host and token must be specified (-t / -m)"
        fi
        local IS_ACTIVE_WORKER=$(docker system info --format '{{json .}}' | jq -r '.Swarm | has("RemoteManagers") and .LocalNodeState=="active" and .ControlAvailable == false')
        if [ "${IS_ACTIVE_WORKER}" == "false" ]; then
            docker swarm join --token ${SWARM_TOKEN} ${SWARM_HOST}:2377 > /dev/null 2>&1
        fi
    fi
}

function sink {
    if [ -z $FIX ]; then
        usage_sink
        die "A prefix must be provided to sink"
    fi
    if [ -z "$(docker ps -q -f "name=$FIX")" ]; then
        echo "Nothing to stop"
    else
        docker stop $(docker ps -q -f "name=$FIX")
    fi
    if [ -z "$(docker ps -a -q -f "name=$FIX")" ]; then
        echo "Nothing to remove"
    else
        docker rm $(docker ps -a -q -f "name=$FIX")
    fi
    if [ -z "$(docker stack ls | grep ${FIX})" ]; then
        echo "No stack to remove"
    else
        docker stack rm ${FIX}
    fi
    if [ -z "$(docker network ls | grep ${FIX}_default)" ]; then
        echo "No network to remove"
    else
        docker network rm ${FIX}_default
    fi
}

function board {
    if [ -z $FIX ]; then
        usage_board
        die "A prefix must be provided to board"
    fi
    if [ -z "$(docker ps -q -f "name=$FIX")" ]; then
        echo "Nothing to board"
    else
        docker exec -i -t $FIX /bin/bash
    fi
}

function list {
    echo "Nodes:"
    docker node ls --format "{{.Hostname}} {{.Status}} ({{.ID}}) {{.ManagerStatus}}" | sed -e 's/^/\t/' | column -t -s' '

    STACK_COUNT=$(docker stack ls | tail -n+2 | wc -l)
    if [ -z "$WORK" ] && [ "$STACK_COUNT" != "1" ] && [ "$STACK_COUNT" != "0" ]; then
        echo "Available stacks:"
        docker stack ls | sed -e 's/^/\t/' | column -t -s' '
    fi

    # only 1 stack?
    if [ "$STACK_COUNT" == "1" ]; then
        # select it
        WORK=$(docker stack ls | tail -n+2 | head -n1 | cut -f1 -d' ')
    fi

    # showing 1 stack?
    if [ ! -z "$WORK" ]; then
        echo "Stack:"
        docker stack ls | tail -n+2 | grep "$WORK " | sed -e 's/^/\t/' | column -t -s' '

        echo -e "Ports\thost -> target:"
        PORT_COUNT=$(docker service inspect ${WORK}_proxy | jq -r '.[0].Endpoint.Ports | length')
        for PORT in $(seq 0 $(expr $PORT_COUNT - 1)); do
            HOST_PORT=$(docker service inspect ${WORK}_proxy | jq -r ".[0].Endpoint.Ports | .[$PORT] | .PublishedPort")
            TARGET_PORT=$(docker service inspect ${WORK}_proxy | jq -r ".[0].Endpoint.Ports | .[$PORT] | .TargetPort")
            echo -e "\t$HOST_PORT -> $TARGET_PORT"
        done | column -t -s ' '

        echo "Images:"
        docker service ls --format "{{.Name}} {{.Image}}" | grep ${WORK}_ | while read S; do
            local SERVICE_NAME=$(echo $S | awk '{print $1}')
            local SERVICE_IMAGE=$(echo $S | awk '{print $2}')
            echo -e "\t${SERVICE_NAME} -> ${SERVICE_IMAGE}"
        done  | column -t -s' '

        echo "Running:"
        docker service ls --format "{{.Name}} {{.Image}}" | grep ${WORK}_ | while read S; do
            local SERVICE_NAME=$(echo $S | awk '{print $1}')
            local SERVICE_IMAGE=$(echo $S | awk '{print $2}')
            docker service ps ${SERVICE_NAME} --format '{{.Name}} {{.Node}} {{.CurrentState}} {{.Error}}' -f 'desired-state = running' -f 'desired-state = accepted'| while read PS; do
                local NAME=$(echo $PS | awk '{print $1}')
                local NODE=$(echo $PS | awk '{print $2}')
                local REST=$(echo $PS | cut -d' ' -f3-)
                local INSTANCE=$(docker ps --format "{{.Names}}" -f "name=${NAME}")
                if [ -z "${INSTANCE}" ]; then
                    INSTANCE="${NAME}[remote]"
                fi
                echo -e "\t${NODE} -> ${INSTANCE} ${REST}"
            done
        done  | column -t -s' '
    fi
}

case $CMD in
    build)
        build
        ;;
    deploy)
        deploy
        ;;
    sink)
        sink
        ;;
    board|shell)
        board
        ;;
    ls|list)
        list
        ;;
    logs)
        logs
        ;;
    containers)
        containers
        ;;
esac

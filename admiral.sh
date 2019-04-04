#!/bin/bash

# A script for setting up a dockerised instance of HA Proxy which forwards to a number of other instances.

# Set up parameters
APP=$0
ARG="LATEST"
NAME=$(cat $CONFIG_DIR/stack-name)
DRY_RUN=no
DEV_MODE=no
REPORT_ENV=no
STDOUT=/dev/null
NODE_LABEL=general
SMOKE_TEST="no"
DO_DEPLOY="yes"
SWARM_HOST=
SWARM_TOKEN=
REMOTE_DEBUG=
SERVICES_FILE=services
CLUSTER_FILE=
SHOW_SPINNER="yes"
FORCE_LATEST="no"
ADMIRAL_SRC_DIR="${ADMIRAL_SRC_DIR}"
LOCAL_SRC_SERVICES=()
QUICK_MODE="no"

function die
{
    echo "$1"
    exit 1
}

if ! valenv MANIFEST_REPO DEPLOY_REPO CONFIG_DIR SSH_PORT GIT_HOST HTTP_PORT HTTPS_PORT STATS_PORT REGISTRY; then exit 1; fi

# does array contain an element?
function containsElement ()
{
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

if ! fleet ls >/dev/null 2>&1; then
    die "No fleet. Check your path."
fi

if ! groups | grep docker >/dev/null 2>&1; then
    die "You must belong to docker group."
fi

if [ ! -d ${CONFIG_DIR} ]; then
    die "Config dir missing: $CONFIG_DIR"
fi

if [ ! -e ${CONFIG_DIR}/stack-name ]; then
    die "No stack name found in $CONFIG_DIR/stack-name"
fi
if [[ `docker info --format '{{json .}}' | jq -r '.RegistryConfig | .IndexConfigs | has("'$REGISTRY'") | not'` == "true" ]]; then
    die "$REGISTRY is not known to docker. Try restarting docker?"
fi


function notify()
{
    local NOTIFY_CHANNEL=$1
    local NOTIFY_MSG=$2
    local NOTIFY_URI=$(cat $CONFIG_DIR/slack-notify)
    if [ -n "${NOTIFY_CHANNEL}" ]; then
        curl -X POST -k -H 'Content-type: application/json' \
             --data '{"username":"'"$USER@$HOSTNAME"'","icon_emoji":":admiral:","channel":"'"$NOTIFY_CHANNEL"'","text":"'"$NOTIFY_MSG"'"}]}' \
             $NOTIFY_URI > /dev/null 2>&1
    fi
}


function show_spinner()
{
    if [ "${SHOW_SPINNER}" == "yes" ]; then
        if [ $STDOUT != "/dev/stdout" ]; then
            local -r pid="${1}"
            local -r delay='0.75'
            local spinstr='\|/-'
            local temp
            while ps a | awk '{print $1}' | grep -q "${pid}"; do
                temp="${spinstr#?}"
                printf "%c   " "${spinstr}"
                spinstr=${temp}${spinstr%"${temp}"}
                sleep "${delay}"
                printf "\b\b\b\b\b\b"
            done
            printf "    \b\b\b\b"
        fi
    fi
}

function run_or_die
{
    ("$@" > $STDOUT 2>&1) &
    show_spinner "$!"
    wait $!
    STATUS=$?
    if [ "$STATUS" != "0" ]; then
        die "status: $STATUS: unable to run: $*"
    fi
    return $STATUS
}

function usage
{
    echo
    echo "Usage: $APP [ARG] [NAME] [OPTIONS]"
    echo "A shell script for administrating a cluster."
    echo
    echo "Optional:"
    echo
    echo "ARG                  A local services file or the manifest tag or LATEST."
    echo "NAME                 Name of the stack"
    echo
    echo " -p, --http-port     HTTP port to listen on (default: ${HTTP_PORT})"
    echo " -s, --https-port    HTTPS port to listen on (default: ${HTTPS_PORT})"
    echo " -a, --stats-port    Stats port to listen on (default: ${STATS_PORT})"
    echo " -n, --name NAME     Name of stack"
    echo " -e, --services NAME Name of services file (default: ${SERVICES_FILE}"
    echo " -b, --remote-access Service to allow ssh access to"
    echo
    echo "Optional:"
    echo " -S, --nospinner     Do not show a spinner while waiting for commands"
    echo " -t, --token TOKEN   Swarm token for joining"
    echo " -m, --manager HOST  Manager host to join"
    echo " -l, --label LABEL   Node label (default: ${NODE_LABEL}"
    echo " -d, --dev           Dev-mode, allowing execution of this script with local changes"
    echo " -v, --verbose       Lots of output"
    echo " -c, --cluster NAME  Name of cluster file"
    echo " -L, --force-latest  Force the use of LATEST for all tags"
    echo " --admiral-src-dir   Local location for source code (see --local)."
    echo " --local SERVICE     Specify that ${ADMIRAL_SRC_DIR}/${SERVICE} should be preferred."
    echo "                     This option can be specified multiple times"
    echo " -q, --quick         Do the deployment using keel - the new experimental faster deployment method"
    echo "                     This option requires that all images have been pushed and does not handle worker-joining"
    echo
    echo "Optional (skips deployment):"
    echo " -x, --do-not-deploy Do not actually deploy"
    echo " -k, --smoke-test    Run smoke tests"
    echo " --dry-run           Don't do anything; just report it"
    echo " --env               Report the environment"
}

POS1=
POS2=
while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -h|--help)
            usage
            exit
            ;;
        -p|--http-port)
            HTTP_PORT="$2"
            shift # past argument
            ;;
        -s|--https-port)
            HTTPS_PORT="$2"
            shift # past argument
            ;;
        -a|--stats-port)
            STATS_PORT="$2"
            shift # past argument
            ;;
        -S|--nospinner)
            SHOW_SPINNER="no"
            ;;
        -L|--force-latest)
            FORCE_LATEST="yes"
            ;;
        -n|--name)
            NAME="$2"
            shift # past argument
            ;;
        --local)
            LOCAL_SRC_SERVICES=("${LOCAL_SRC_SERVICES[@]}" "$2")
            shift # past argument
            ;;
        --admiral-src-dir)
            ADMIRAL_SRC_DIR="$2"
            shift # past argument
            ;;
        -c|--cluster)
            CLUSTER_FILE="$2"
            shift # past argument
            ;;
        -e|--services)
            SERVICES_FILE="$2"
            shift # past argument
            ;;
        -l|--label)
            NODE_LABEL="$2"
            shift # past argument
            ;;
        -b|--remote-access)
            REMOTE_ACCESS=(${2//,/ })
            shift # past argument
            ;;
        -v|--verbose)
            STDOUT="/dev/stdout"
            ;;
        --dry-run)
            DRY_RUN="yes"
            ;;
        -x|--do-not-deploy)
            DO_DEPLOY="no"
            ;;
        -k|--smoke-test)
            SMOKE_TEST="yes"
            DO_DEPLOY="no"
            ;;
        -t|--token)
            SWARM_TOKEN="$2"
            shift # past argument
            ;;
        -m|--manager)
            SWARM_HOST="$2"
            shift # past argument
            ;;
        -d|--dev)
            DEV_MODE="yes"
            ;;
        -q|--quick)
            QUICK_MODE="yes"
            ;;
        --env)
            REPORT_ENV="yes"
            ;;
        *)
            if [ -z "$POS1" ]; then
                POS1="$key"
            else
                if [ -z "$POS2" ]; then
                    POS2="$key"
                fi
            fi
            ;;
    esac
    shift # past argument or value
done

if [ -n "$POS1" ]; then
    ARG=$POS1
fi
if [ -n "$POS2" ]; then
    NAME=$POS2
fi

# get all mount paths, excluding "/"
function mount_paths()
{
    cat /proc/mounts | cut -d" " -f2 | grep -v "^\/$"
}

# find a corresponding mount given a path
function find_mount()
{
    for mp in $(mount_paths); do
        if echo $1 | grep $mp > /dev/null; then
            return 0;
        fi
    done
    return 1;
}

# recursively try to find a mount path
# given: /my/mount/here
# look for: /my/mount/here
#           /my/mount
#           /my
function upsearch_mount ()
{
    P=$1
    if [[ $P == /* ]]; then
        test / == "$P" && return 0 ||
                find_mount $P && return 1 ||
                        upsearch_mount "$(dirname $P)"
    else
        return 1
    fi
}

function get_dockerfile()
{
    local FILE=$1
    local SERVICE=$2
    local DOCKERFILE=$(cat $FILE | jq -r ".services.$SERVICE | select(.dockerfile != null) | .dockerfile")
    if [ -z "${DOCKERFILE}" ]; then
        DOCKERFILE="Dockerfile"
    fi
    echo $DOCKERFILE
}

function validate_json
{
    if [ -e $1 ]; then
        cat $1 | jq -e . >/dev/null 2>&1 || die "Invalid JSON: $1"
    fi
}

function meta_file_syntax_check()
{
    local META=$1
    local DATA=$2
    for D in $(echo -e $DATA); do
        local BUILD_DIR=$(echo $D | cut -d: -f2)
        local DOCKERFILE=$(echo $D | cut -d: -f4)
        META_FILE=${BUILD_DIR}/$(dirname $DOCKERFILE)/meta/${META}
        validate_json $META_FILE
    done
}

function all_meta()
{
    local META=$1
    local DATA=$2
    local ALL_META=
    for D in $(echo -e $DATA); do
        local BUILD_DIR=$(echo $D | cut -d: -f2)
        local DOCKERFILE=$(echo $D | cut -d: -f4)
        META_FILE=${BUILD_DIR}/$(dirname $DOCKERFILE)/meta/${META}
        if [ -e "${META_FILE}" ]; then
            local M=$(cat ${META_FILE} | jq -r ".${META} | .[]")
            ALL_META="${M} ${ALL_META}"
        fi
    done
    echo $ALL_META
}

function echo_env_errors
{
    local NAME=$1
    local ERRORS=$2

    if [ ! -z "${ERRORS}" ]; then
        echo "${NAME} Errors:"
        echo -e "${ERRORS}"
    else
        echo "${NAME} OK"
    fi

}
# check every aspect of the specified services file and ensure all
# necessary aspects are present on the host system
function report_env
{
    local DATA=$1

    ALL_SERVICES=
    for D in $(echo -e $DATA); do
        local SERVICE=$(echo $D | cut -d: -f1)
        ALL_SERVICES="${SERVICE} ${ALL_SERVICES}"
    done

    meta_file_syntax_check "config" $DATA
    meta_file_syntax_check "volumes" $DATA
    meta_file_syntax_check "host_volumes" $DATA

    ALL_CONFIG=$(all_meta "config" $DATA)
    MOUNTED_VOLUMES=$(all_meta "volumes" $DATA)
    HOST_VOLUMES=$(all_meta "host_volumes" $DATA)

    CONFIG_CRLF=$(git config --get --global core.autocrlf)

    echo "Environment:" >$STDOUT
    echo -e "\tSERVICES    : $(echo ${ALL_SERVICES})" >$STDOUT
    echo -e "\tMOUNTED VOLS: $(echo -e ${MOUNTED_VOLUMES} | sed -e 's/ /\n\t\t/g')" >$STDOUT
    echo -e "\tHOST VOLS  :$(echo -e ${HOST_VOLUMES} | sed -e 's/ /\n\t\t/g')" >$STDOUT
    echo -e "\tCONFIG DIR  : ${CONFIG_DIR}" >$STDOUT
    echo -e "\tUSED CONFIG : $(echo ${ALL_CONFIG})" >$STDOUT
    echo -e "\tCRLF         : ${CONFIG_CRLF}" >$STDOUT
    echo

    BAD_CRLF=
    if [ "${CONFIG_CRLF}" == "true" ]; then
        BAD_CRLF="**git autocrlf is true, and should be false**\n"
    fi
    echo_env_errors "CRLF" "${BAD_CRLF}"

    # check each config file
    MISSING_CONFIG=
    for CONFIG in ${ALL_CONFIG}; do
        if [ ! -e ${CONFIG_DIR}/${CONFIG} ]; then
            MISSING_CONFIG="${MISSING_CONFIG}**MISSING CONFIG** : ${CONFIG_DIR}/${CONFIG}\n"
        fi
    done
    echo_env_errors "CONFIG" "${MISSING_CONFIG}"

    # check each mount exists
    MISSING_MOUNTS=
    for VOL in ${MOUNTED_VOLUMES}; do
        MOUNT=$(echo $VOL | cut -d: -f1)
        if [ ! -f $MOUNT ]; then
            if upsearch_mount $MOUNT; then
                MISSING_MOUNTS="${MISSING_MOUNTS}**MISSING MOUNT** : ${MOUNT}\n"
            fi
        fi
    done
    for VOL in ${HOST_VOLUMES}; do
        MOUNT=$(echo $VOL | cut -d: -f1)
        if [ ! -e $MOUNT ]; then
            MISSING_MOUNTS="${MISSING_MOUNTS}**MISSING MOUNT** : ${MOUNT}\n"
        fi
    done
    ALL_VOLUMES=("${ALL_VOLUMES[@]}" "${HOST_VOLUMES[@]}")
    echo_env_errors "MOUNTS" "${MISSING_MOUNTS}"

    # check rsyslog config
    MISSING_RSYSLOG_CONF=
    if [ ! -e /etc/rsyslog.d/30-docker.conf ]; then
        MISSING_RSYSLOG_CONF="**MISSING rsyslog configuration**\n"
    fi
    echo_env_errors "RSYSLOG" "${MISSING_RSYSLOG_CONF}"

    ERRORS="${BAD_CRLF}${MISSING_CONFIG}${MISSING_MOUNTS}${MISSING_RSYSLOG_CONF}"

    if [ ! -z "${ERRORS}" ]; then
        echo
        echo "ERRORS - Environment NOT OK"
        return 1
    fi

    echo "Environment OK."
    return 0
}

if [ "${DRY_RUN}" == "yes" ]; then
    echo "*** DRY RUN ***"
fi

if [ "${REPORT_ENV}" == "no" ]; then
    if [ -z "$NAME" ]; then
        usage
        die "Missing name"
    fi
    if [ -z "$HTTP_PORT" ]; then
        usage
        die "Missing http port (-p)"
    fi
    if [ -z "$HTTPS_PORT" ]; then
        usage
        die "Missing https port (-s)"
    fi
    if [ -z "$STATS_PORT" ]; then
        usage
        die "Missing stats port (-a)"
    fi
    if [ -z "$ARG" ]; then
        usage
        die "Please provide a manifest location"
    fi

    echo "Deploying stack from $ARG on ports $HTTP_PORT, $HTTPS_PORT, $STATS_PORT"
fi

function adjust_vector
{
    ADJUST_FILE=$1
    ADJUST_SERVICE=$2
    ADJUST_VECTOR=$3
    ADJUST_COMPOSE=$4

    # get list of all the desired things
    THINGS=$(cat ${ADJUST_FILE} | jq -r ".services.${ADJUST_SERVICE} | select(.${ADJUST_VECTOR} != null) | .${ADJUST_VECTOR} | .[]")
    if [ ! -z "$THINGS" ]; then
        # determine indentation; use # for spaces, replaced below
        LEADING_SPACES_COUNT=$(cat ${ADJUST_COMPOSE} | grep "\$${ADJUST_SERVICE}_${ADJUST_VECTOR}" | awk -F'[^ ]' '{print length($1)}')
        LEADING_SPACES=$(echo "$(seq -s '#' ${LEADING_SPACES_COUNT} | sed -e 's/[0-9]//g')###-#")
        THING_STRING="${ADJUST_VECTOR}:\n"
        for THING in $THINGS; do
            THING_STRING="${THING_STRING}${LEADING_SPACES}${THING}\n"
        done
        THING_STRING=$(echo "$THING_STRING" | sed -e "s:/:\\\\/:g")
        THING_STRING=$(echo "$THING_STRING" | sed -e "s/\#/ /g")
        sed -i "s/\$${ADJUST_SERVICE}_${ADJUST_VECTOR}/${THING_STRING}/" ${ADJUST_COMPOSE}
    else
        sed -i "/\$${ADJUST_SERVICE}_${ADJUST_VECTOR}/d" ${ADJUST_COMPOSE}
    fi
}

function adjust_meta
{
    local ADJUST_SERVICE=$1
    local ADJUST_META_DIR=$2
    local ADJUST_COMPOSE=$3
    local ADJUST_META=$4
    local ADJUST_FILE=${ADJUST_META_DIR}/${ADJUST_META}

    if [ -e "${ADJUST_FILE}" ]; then

        validate_json $ADJUST_FILE

        # get list of all the desired things
        THINGS=$(cat ${ADJUST_FILE} | jq -r ".${ADJUST_META} | .[]")

        # determine indentation; use # for spaces, replaced below
        LEADING_SPACES_COUNT=$(cat ${ADJUST_COMPOSE} | grep "\$${ADJUST_SERVICE}_${ADJUST_META}" | awk -F'[^ ]' '{print length($1)}')
        LEADING_SPACES=$(echo "$(seq -s '#' ${LEADING_SPACES_COUNT} | sed -e 's/[0-9]//g')###-#")
        THING_STRING="\n"
        for THING in $THINGS; do
            case "${ADJUST_META}" in
                volumes)
                    THING_STRING="${THING_STRING}${LEADING_SPACES}${THING}\n"
                    ;;
                host_volumes)
                    THING_STRING="${THING_STRING}${LEADING_SPACES}${THING}\n"
                    ;;
                config)
                    THING_STRING="${THING_STRING}${LEADING_SPACES}${CONFIG_DIR}/$THING:${CONFIG_DIR}/${THING}:ro\n"
                    ;;
                default)
                    die "unknown meta type: ${ADJUST_META}"
            esac
        done
        THING_STRING=$(echo "$THING_STRING" | sed -e "s:/:\\\\/:g")
        THING_STRING=$(echo "$THING_STRING" | sed -e "s/\#/ /g")
        if [ -n "${THING_STRING}" ]; then
            sed -i "s/\$${ADJUST_SERVICE}_${ADJUST_META}/${THING_STRING}/" ${ADJUST_COMPOSE}
        else
            sed -i "/\$${ADJUST_SERVICE}_${ADJUST_META}/d" ${ADJUST_COMPOSE}
        fi
    else
        sed -i "/\$${ADJUST_SERVICE}_${ADJUST_META}/d" ${ADJUST_COMPOSE}
    fi
}

function adjust_entry
{
    local ADJUST_FILE=$1
    local ADJUST_SERVICE=$2
    local ADJUST_ENTRY=$3
    local ADJUST_DEFAULT=$4
    local ADJUST_COMPOSE=$5

    local ENTRY=$(cat ${ADJUST_FILE} | jq -r ".services.${ADJUST_SERVICE} | select(.${ADJUST_ENTRY} != null) | .${ADJUST_ENTRY}")
    if [ ! -z "$ENTRY" ]; then
        sed -i "s/\$${ADJUST_SERVICE}_${ADJUST_ENTRY}/${ENTRY}/" ${ADJUST_COMPOSE}
    else
        sed -i "s/\$${ADJUST_SERVICE}_${ADJUST_ENTRY}/${ADJUST_DEFAULT}/" ${ADJUST_COMPOSE}
    fi
}

CLEANUP_DIRS=
function add_cleanup
{
    CLEANUP_DIRS="${CLEANUP_DIRS} $1"
}
function cleanup_handler
{
    for i in ${CLEANUP_DIRS}; do
        rm -rf ${i}
    done
}
trap cleanup_handler EXIT


function clone()
{
    TEMP_DIR=$(mktemp -d)
    add_cleanup ${TEMP_DIR}

    local FILE=$1
    local DATA=

    SERVICES=$(cat $FILE | jq -r '.services | keys | .[]')
    for SERVICE in $SERVICES; do

        local BUILD_DIR=
        local SUFFIX=
        local DOCKERFILE=$(get_dockerfile $FILE $SERVICE)

        echo "Evaluating ${SERVICE}..."

        # figure out how to get the source
        GIT=$(cat $FILE | jq -r ".services.$SERVICE | select(.git != null) | .git")
        DIR=$(cat $FILE | jq -r ".services.$SERVICE | select(.dir != null) | .dir")

        if [ ! -z "$GIT" ]; then
            # check for local source override
            local SRC_NAME="$(basename $GIT)"
            if containsElement "${SERVICE}" "${LOCAL_SRC_SERVICES[@]}"; then
                local LOCAL_SRC="${ADMIRAL_SRC_DIR}/${SRC_NAME}"
                if [ ! -e "${LOCAL_SRC}" ]; then
                    die "Local source for $LOCAL_SRC does not exist!"
                fi
                echo "Using local source for $SERVICE: $LOCAL_SRC"
                GIT=""
                DIR="${LOCAL_SRC}"
            fi
        fi

        if [ ! -z "$GIT" ]; then
            if ! git ls-remote ${GIT_HOST}/${GIT}.git >/dev/null 2>&1; then
                die "Configuration error, cannot access git repo at $GIT"
            fi
            TAG=$(cat $FILE | jq -r ".services.$SERVICE.tag")
            BRANCH=$(cat $FILE | jq -r ".services.$SERVICE | select(.branch != null) | .branch")
            USE_BRANCH="no"
            # If BRANCH is specified, it takes precedence over everything
            if [ -z "$BRANCH" ]; then
                BRANCH=$TAG
            else
                USE_BRANCH="yes"
                FORCE_LATEST="no"
            fi
            local FORCE_LATEST_DESC=
            if [ "${BRANCH}" != "LATEST" ] && [ "${FORCE_LATEST}" == "yes" ]; then
                BRANCH="LATEST"
                FORCE_LATEST_DESC="(forced)"
            fi
            if [ "$BRANCH" == "LATEST" ]; then
                BRANCH=$(git ls-remote --tags --refs ${GIT_HOST}/${GIT}.git | sort -t '/' -k 3 -V | tail -n1 | cut -d "/" -f 3)
                echo " Using latest tag for ${SERVICE}: $BRANCH ${FORCE_LATEST_DESC}"
            else
                echo " Using specified tag for ${SERVICE}: $BRANCH"
            fi

            # use the specified branch/tag string
            SUFFIX=$(echo ${BRANCH} | tr '[:upper:]' '[:lower:]')
            # replace all forward slashes with 2 underscores to comply with docker tags
            SUFFIX=${SUFFIX//\//__}

            # If we are using a branch we need the commit hashsum to distinguish docker images
            if [ "${USE_BRANCH}" == "yes" ]; then
                COMMIT=$(git ls-remote -h --refs ${GIT_HOST}/${GIT}.git ${BRANCH} | grep refs/heads/${BRANCH} | cut -c1-7)
                SUFFIX="${SUFFIX}_${COMMIT}"
            fi
            BUILD_DIR=${TEMP_DIR}/${SERVICE}${SUFFIX}
            run_or_die git clone -c advice.detachedHead=false ${GIT_HOST}/${GIT}.git --recurse-submodules --branch $BRANCH --depth=1 ${BUILD_DIR}
        fi

        # dir?
        if [ ! -z "$DIR" ]; then
            echo " Copying local repo: $DIR"
            # replace '~' with $HOME, necessary since '~' is a literal string and won't be expanded
            if ! cp -a "${DIR/#~/$HOME}" "${TEMP_DIR}/$SERVICE"; then
                die "Unable to copy local repo: $DIR"
            fi
            BUILD_DIR=${TEMP_DIR}/$SERVICE
            pushd ${TEMP_DIR}/$SERVICE > /dev/null
            SUFFIX=local_$(git describe --tags --dirty --always)-$(git diff 2>/dev/null | sha1sum | cut -c1-7)
            popd > /dev/null
        fi

        DATA="$SERVICE:$BUILD_DIR:$SUFFIX:$DOCKERFILE\n$DATA"
    done

    # pass back by reference
    eval "$2=\"${DATA}\""
}

function is_running
{
    local SERVICE=$1
    local RVAL=0
    local REPLICAS=$(docker service ls | grep ${PREFIX}_${SERVICE} | awk '{print $4;}')
    local RUNNING=$(echo $REPLICAS | cut -d/ -f1)
    local TOTAL=$(echo $REPLICAS | cut -d/ -f2)
    if [ "${TOTAL}" != "0" ]; then
        if [ "${RUNNING}" != "0" ]; then
            RVAL=0
        else
            RVAL=1
        fi
    fi
    return $RVAL
}

function wait_for_services
{
    local CLONED=$1
    local PROXY_WAIT="1s"
    for D in $(echo -e $CLONED); do
        local SERVICE=$(echo $D | cut -d: -f1)
        if [ "${SERVICE}" == "proxy" ]; then
            local BUILD_DIR=$(echo $D | cut -d: -f2)
            PROXY_WAIT=$(grep "timeout check" ${BUILD_DIR}/haproxy.cfg | awk '{print $3}')
        fi
        while ! is_running $SERVICE; do
            sleep 1
            echo "  waiting for $SERVICE..." >$STDOUT
        done
    done
    echo "  waiting $PROXY_WAIT for proxy..." >$STDOUT
    sleep $PROXY_WAIT $PROXY_WAIT $PROXY_WAIT
}

function smoke
{
    local CLONED=$1
    wait_for_services $CLONED
    for D in $(echo -e $CLONED); do
        local SERVICE=$(echo $D | cut -d: -f1)
        local BUILD_DIR=$(echo $D | cut -d: -f2)
        # determine if there is a smoke test
        if [ -e "${BUILD_DIR}/meta/smoke.sh" ]; then
            pushd ${BUILD_DIR} > /dev/null
            echo " Smoke: ${SERVICE}" >$STDOUT
            ./meta/smoke.sh || die "Failed smoke test: ${SERVICE}"
            popd > /dev/null
        fi
    done
}

function index_in_array
{
    local VALUE=$1
    shift
    local ARRAY=("$@")

    for i in "${!ARRAY[@]}"; do
        if [[ "${ARRAY[$i]}" = "${VALUE}" ]]; then
            echo "${i}";
        fi
    done
}

function file_load
{
    FILE=$1

    # validate services file
    if ! cat $FILE | jq -r '.' > /dev/null 2>&1; then
        die "Invalid services file, check your JSON: $FILE"
    fi

    CLONED=''
    clone $FILE CLONED

    if ! report_env $CLONED; then
        die "environment failure"
    fi
    if [ "${REPORT_ENV}" == "yes" ]; then
        exit 0
    fi

    TEMP_DIR=$(mktemp -d)
    add_cleanup ${TEMP_DIR}

    # grab the base stack
    cp $(dirname $FILE)/compose* ${TEMP_DIR}
    SERVICE_TEMPLATE=${TEMP_DIR}/compose.service

    for D in $(echo -e $CLONED); do
        local SERVICE=$(echo $D | cut -d: -f1)
        local BUILD_DIR=$(echo $D | cut -d: -f2)
        local SUFFIX=$(echo $D | cut -d: -f3)
        local DOCKERFILE=$(echo $D | cut -d: -f4)

        echo "Service: ${SERVICE}"
        echo " Using docker file: ${DOCKERFILE}"

        # get hash
        local HEAD_HASH=$(git --git-dir ${BUILD_DIR}/.git rev-parse --short HEAD)
        local IMAGE_NAME=${SERVICE}
        local IMAGE_SUFFIX=${SUFFIX}

        echo " Fleet: ${SERVICE}:${IMAGE_SUFFIX} in ${BUILD_DIR}"

        if [ "${DRY_RUN}" == "no" ]; then
            # build it
            run_or_die fleet build ${BUILD_DIR} -d ${DOCKERFILE} -n $IMAGE_NAME -s $IMAGE_SUFFIX -a ${HEAD_HASH}
        fi

        cat ${SERVICE_TEMPLATE} | sed -e "s/SERVICE/$SERVICE/g" > ${TEMP_DIR}/compose.$SERVICE

        # adjust image
        sed -i "s/\$${SERVICE}_image_name/${IMAGE_NAME}:${IMAGE_SUFFIX}/" ${TEMP_DIR}/compose.$SERVICE

        # adjust vectors
        META_DIR=${BUILD_DIR}/$(dirname ${DOCKERFILE})/meta
        adjust_meta   $SERVICE $META_DIR ${TEMP_DIR}/compose.$SERVICE volumes
        adjust_meta   $SERVICE $META_DIR ${TEMP_DIR}/compose.$SERVICE host_volumes
        adjust_meta   $SERVICE $META_DIR ${TEMP_DIR}/compose.$SERVICE config
        adjust_vector $FILE $SERVICE depends_on ${TEMP_DIR}/compose.$SERVICE

        # adjust entries
        # are replicas required?
        local MODE=$(cat ${FILE} | jq -r ".services.${SERVICE} | select(.mode != null) | .mode")
        if [ "${MODE}" != "global" ]; then
            sed -i "s/\$${SERVICE}_replicas/replicas: \$${SERVICE}_replicas/" ${TEMP_DIR}/compose.$SERVICE
            adjust_entry $FILE $SERVICE replicas 1 ${TEMP_DIR}/compose.$SERVICE
        else
            sed -i "/\$${SERVICE}_replicas/d" ${TEMP_DIR}/compose.$SERVICE
        fi
        adjust_entry $FILE $SERVICE mode replicated ${TEMP_DIR}/compose.$SERVICE
        adjust_entry $FILE $SERVICE cpus 1 ${TEMP_DIR}/compose.$SERVICE
        adjust_entry $FILE $SERVICE memory 50M ${TEMP_DIR}/compose.$SERVICE
        adjust_entry $FILE $SERVICE node_label general ${TEMP_DIR}/compose.$SERVICE
        adjust_entry $FILE $SERVICE command "" ${TEMP_DIR}/compose.$SERVICE

        # accumulate
        cat ${TEMP_DIR}/compose.$SERVICE >> ${TEMP_DIR}/compose.all

        # add special section for the ports which handle incoming traffic
        REMOTE_ACCESS_INDEX=$(index_in_array ${SERVICE} ${REMOTE_ACCESS[@]})
        if [ "${SERVICE}" == "proxy" ]; then
            cat ${TEMP_DIR}/compose.ports >> ${TEMP_DIR}/compose.all
            if [ -n "${REMOTE_ACCESS_INDEX}" ]; then
                head -n2 ${TEMP_DIR}/compose.ports | tail -n1 | sed "s/[^ \"]*:[^ \"]*/$((${SSH_PORT} + ${REMOTE_ACCESS_INDEX})):22/" >> ${TEMP_DIR}/compose.all
            fi
        elif [ -n "${REMOTE_ACCESS_INDEX}" ]; then
            head -n1 ${TEMP_DIR}/compose.ports >> ${TEMP_DIR}/compose.all
            head -n2 ${TEMP_DIR}/compose.ports | tail -n1 | sed "s/[^ \"]*:[^ \"]*/$((${SSH_PORT} + ${REMOTE_ACCESS_INDEX})):22/" >> ${TEMP_DIR}/compose.all
        fi
    done


    # put all services into the compose file
    # since we replace the whole line, run both r and d when there's a match.
    # put them in a braced group.
    sed -e "/\$services/{" -e "r ${TEMP_DIR}/compose.all" -e "d" -e "}" -i ${TEMP_DIR}/compose

    # adjust ports
    sed -i "s/\$http_port/${HTTP_PORT}/" ${TEMP_DIR}/compose
    sed -i "s/\$https_port/${HTTPS_PORT}/" ${TEMP_DIR}/compose
    sed -i "s/\$stats_port/${STATS_PORT}/" ${TEMP_DIR}/compose

    if [ "${DRY_RUN}" == "no" ]; then
        if [ "${DO_DEPLOY}" == "yes" ]; then
            echo "Deploy: ${PREFIX}"
            local EXTRA_ARGS=
            if [ ! -z "${SWARM_HOST}" ]; then
                EXTRA_ARGS="-m ${SWARM_HOST}"
            fi
            if [ ! -z "${SWARM_TOKEN}" ]; then
                EXTRA_ARGS="${EXTRA_ARGS} -t ${SWARM_TOKEN}"
            fi
            run_or_die fleet deploy $PREFIX -w ${TEMP_DIR}/compose -l ${NODE_LABEL} ${EXTRA_ARGS}
        fi
        if [ "${SMOKE_TEST}" == "yes" ]; then
            echo "Smoke: ${PREFIX}"
            run_or_die smoke $CLONED
        fi
    fi
    if [ "${DRY_RUN}" == "yes" ]; then
        cat ${TEMP_DIR}/compose
        echo "*** DRY RUN ***"
    fi
}

function launch_cluster()
{
    echo "Cluster Mode"
    local CF="${CONFIG_DIR}/${CLUSTER_FILE}"
    if [ ! -e "$CF" ]; then
        die "Unable to find cluster file: ${CF}"
    fi
    # verify master is this host
    local LEADER=$(cat ${CF} | jq -r .cluster.leader.hostname)
    if [ "${LEADER}" != "${HOSTNAME}" ]; then
        die "This machine is not the leader specified in the cluster file"
    fi
    # obtain notification channel
    local SLACK_CHANNEL=""
    if [ -e "${CONFIG_DIR}/slack-channel-cluster-activity" ]; then
        SLACK_CHANNEL=$(cat ${CONFIG_DIR}/slack-channel-cluster-activity)
        echo "Notifying $SLACK_CHANNEL"
    fi

    notify "${SLACK_CHANNEL}" "Launching cluster: ${CLUSTER_FILE}"

    # make sure cluster is running here
    echo "Initializing swarm..."
    local INT_IP=$(ip route get 8.8.8.8 | awk '{print $NF; exit}') # internal IP
    docker swarm init --advertise-addr $INT_IP > /dev/null 2>&1

    local JT=$(docker swarm join-token worker -q)
    if [ -z "$JT" ]; then
        notify "${SLACK_CHANNEL}" "No worker join token! Is the cluster running?"
        die "No worker join token! Is the cluster running?"
    fi
    echo "Using join token: ${JT}"

    local EXTRA_ARGS=
    if [ "${DEV_MODE}" == "yes" ]; then
        EXTRA_ARGS="$EXTRA_ARGS --dev"
    fi
    if [ "${STDOUT}" != "/dev/null" ]; then
        EXTRA_ARGS="$EXTRA_ARGS -v"
    fi
    if [ "${FORCE_LATEST}" == "yes" ]; then
        EXTRA_ARGS="$EXTRA_ARGS -L"
    fi

    if [[ "${QUICK_MODE}" = "yes" ]]; then
        echo "Quick mode"
        MANIFEST_TEMP_DIR=$(mktemp -d)
        add_cleanup ${MANIFEST_TEMP_DIR}
        if [ "$ARG" == "LATEST" ]; then
            ARG=$(git ls-remote ${GIT_HOST}/${MANIFEST_REPO}.git | grep refs/tags | sort -t '/' -k 3 -V | tail -n1 | cut -d "/" -f 3)
            echo "Using latest manifest: $ARG"
        fi
        run_or_die git clone ${GIT_HOST}/${MANIFEST_REPO}.git --branch $ARG --depth=1 ${MANIFEST_TEMP_DIR}

        SERVICES_PATH="${MANIFEST_TEMP_DIR}/${SERVICES_FILE}"
        COMPOSE_PATH="${MANIFEST_TEMP_DIR}/docker-compose.yml"
        RESOLVED_SERVICES="${MANIFEST_TEMP_DIR}/resolved.json"
        WORKERS=$(jq -r '.cluster.workers + [.cluster.leader] | .[].hostname' < ${CF})
        echo "Resolving services file"
        keel resolve < ${SERVICES_PATH} > ${RESOLVED_SERVICES}
        echo "Verifying hosts"
        keel verify ${WORKERS} < ${RESOLVED_SERVICES} 2>1
        STATUS=$?
        if [[ "$STATUS" != "0" ]]; then
            die "status: $STATUS: keel verify reported errors"
        fi
        echo "Pulling hosts"
        keel pull ${WORKERS} < ${RESOLVED_SERVICES} 2>1
        STATUS=$?
        if [[ "$STATUS" != "0" ]]; then
            die "status: $STATUS: keel pull reported errors"
        fi
        keel compose < ${RESOLVED_SERVICES} > ${COMPOSE_PATH}
        STATUS=$?
        if [[ "$STATUS" != "0" ]]; then
            die "status: $STATUS: keel compose reported errors"
        fi
        docker stack deploy -c "${COMPOSE_PATH}" ${NAME}
    else
        # process workers first
        for W in $(cat "${CF}" | jq -r ".cluster.workers[] | .hostname + \":\" + .label"); do
            echo "Processing worker: $W..."
            local WORKER_HOST=$(echo "$W" | cut -d":" -f1)
            local WORKER_LABEL=$(echo "$W" | cut -d":" -f2)
            local LABEL_ARGS=${WORKER_HOST}
            if [ "$WORKER_LABEL" != "" ]; then
                LABEL_ARGS="${WORKER_LABEL} --label ${WORKER_LABEL}"
            else
                LABEL_ARGS="--label worker"
            fi
            ssh ${WORKER_HOST} -tt "admiral ${ARG} -e ${SERVICES_FILE} ${LABEL_ARGS} -t ${JT} -m ${LEADER} -S ${EXTRA_ARGS}" | sed "s/^/[$WORKER_HOST] /"
            if [ "${PIPESTATUS[0]}" != "0" ]; then
                notify "${SLACK_CHANNEL}" "Unable to process worker: $W"
                die "Unable to process worker: $W"
            fi
        done
        # process leader
        admiral ${ARG} -e ${SERVICES_FILE} ${EXTRA_ARGS}
    fi


    # upate worker labels
    for W in $(cat "${CF}" | jq -r ".cluster.workers[] | .hostname + \":\" + .label"); do
        local WORKER_HOST=$(echo "$W" | cut -d":" -f1)
        local WORKER_LABEL=$(echo "$W" | cut -d":" -f2)
        if [ "$WORKER_LABEL" != "" ]; then
            echo "Labeling worker: $W..."
            docker node update --label-add ${WORKER_LABEL}=true ${WORKER_HOST}
        fi
    done

    notify "${SLACK_CHANNEL}" "Cluster launched: ${CLUSTER_FILE}"

}

# check freshness of self
if [ "${DEV_MODE}" == "no" ]; then
    DEPLOY_TEMP_DIR=$(mktemp -d)
    add_cleanup ${DEPLOY_TEMP_DIR}
    run_or_die git clone ${GIT_HOST}/${DEPLOY_REPO} --depth=1 ${DEPLOY_TEMP_DIR}
    if ! diff ${BASH_SOURCE[0]} ${DEPLOY_TEMP_DIR}/docker/admiral.sh >$STDOUT; then
        die "this script differs from latest git copy; use --dev only if necessary"
    fi
fi

if [ "$(whoami)" != "admiral" ]; then
    echo
    echo "WARNING: current user might not be configured to deploy to production!"
    echo "Safely ignore this if in dev."
    echo
fi

PREFIX=$NAME

if [ -n "$CLUSTER_FILE" ]; then
    launch_cluster
    exit 0
fi

if [ -e "$ARG" ]; then
    echo "Using local manifest: $ARG"
    file_load "$ARG"
else
    MANIFEST_TEMP_DIR=$(mktemp -d)
    add_cleanup ${MANIFEST_TEMP_DIR}

    if [ "$ARG" == "LATEST" ]; then
        ARG=$(git ls-remote ${GIT_HOST}/${MANIFEST_REPO}.git | grep refs/tags | sort -t '/' -k 3 -V | tail -n1 | cut -d "/" -f 3)
        echo "Using latest manifest: $ARG"
    fi
    run_or_die git clone ${GIT_HOST}/${MANIFEST_REPO}.git --branch $ARG --depth=1 ${MANIFEST_TEMP_DIR}
    file_load "${MANIFEST_TEMP_DIR}/${SERVICES_FILE}"
fi

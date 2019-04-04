#!/bin/bash

function die
{
    echo -e "DIE: $1"
    exit 1
}

if ! version ls >/dev/null 2>&1; then
    die "No 'version' script. Check your path."
fi

if ! valenv NOTIFY_CHANNEL NOTIFY_URI; then exit 1; fi

function usage
{
    echo
    echo "Usage: $APP [OPTIONAL]"
    echo "A shell script for incrementing a remote tag. If repo and branch are not specified it should be run from inside the git repo you wish to bump the version of."
    echo
    echo "Optional:"
    echo " -r, --repo    Full URL of repo to fetch (default is remote fetch)"
    echo " -b, --branch        Remote branch to branch-and-tag (default is remote HEAD)"
    echo " -m, --major         Major version to consider (default is latest tag, e.g. v1.0)"
    echo " -y, --yes           JFDI"
    echo " -t, --tag-only      Do not create a version commit before tagging"
    echo " -a, --annotate      Create an annotated tag with a default message containing the version"
    echo " -L, --legacy        This flag enforces old behaviour (-t and -a are ignored)"
}


while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -h|--help)
            usage
            exit
            ;;
        -r|--repo)
            REPO="$2"
            shift # past argument
            ;;
        -b|--branch)
            BRANCH="$2"
            shift # past argument
            ;;
        -y|--yes)
            PROMPT="NO"
            ;;
        -m|--major)
            MAJOR="$2"
            shift # past argument            
            ;;
        -t|--tag-only)
            TAGONLY="YES"
            ;;
        -a|--annotate)
            ANNOTATE="YES"
            ;;
        -L|--legacy)
            LEGACY="YES"
            ;;
    esac
    shift # past argument or value
done

# First thing, check if legacy is enabled
if [ "${LEGACY}" == "YES" ]; then
    ANNOTATE="NO"
    TAGONLY="NO"
fi

if [ ! -d ".git" ]; then
   if [ -z "$REPO" ] || [ -z "$BRANCH" ]; then
       usage
       exit
   fi
fi

if [ -z "$REPO" ]; then
    REPO=$(git remote show upstream | grep Fetch | awk '{print $3;}')
fi

if [ -z "$BRANCH" ]; then
    BRANCH=$(git remote show upstream | grep HEAD | awk '{print $3;}')
fi 

if [ -z "$PROMPT" ]; then
    PROMPT="YES"
fi

VERSION_CMD="version --repo ${REPO}"
if [ ! -z $MAJOR ]; then
    VERSION_CMD="$VERSION_CMD --major ${MAJOR}"
fi

LATEST_VERSION=$(${VERSION_CMD}) || die "$LATEST_VERSION"

if [ -z "$LATEST_VERSION" ]; then
    if [ -z "$MAJOR" ]; then
        MAJOR="v1.0"
    fi
    MINOR="0"
    LATEST_VERSION="[$MAJOR]"
else
    MAJOR=$(echo $LATEST_VERSION | cut -d"." -f1-2)
    MINOR=$(echo $LATEST_VERSION | cut -d"." -f3)
    MINOR=$(($MINOR+1))
fi

VERSION="$MAJOR"."$MINOR"
echo "Versioning $REPO ($BRANCH)"
echo -e "\t${LATEST_VERSION} -> ${VERSION}"

AGENT_NAME="$(whoami)@$(hostname)"

function notify()
{
        curl -X POST -k -H 'Content-type: application/json' \
            --data '{"username":"'"$AGENT_NAME"'","icon_emoji":":build:","channel":"'"$NOTIFY_CHANNEL"'","text":":build: '"$REPO updated to $VERSION"'"}]}' \
            $NOTIFY_URI > /dev/null 2>&1
}

function update_tag() {
    TEMP_DIR=$(mktemp -d)
    git clone $REPO --branch "$BRANCH" --single-branch "${TEMP_DIR}" > /dev/null 2>&1
    if [ $? -gt 0 ]; then
        die "Unable to clone $BRANCH from $REPO into ${TEMP_DIR}"
    fi
    pushd "$TEMP_DIR" > /dev/null 2>&1

    if [ "${LEGACY}" == "YES" ]; then
        git checkout -b tag-and-deploy-"$VERSION" > /dev/null 2>&1
        PUSH_COMMIT="NO"  # This is the legacy behaviour
        # Legacy means TAGONLY and ANNOTATE are both NO so the rest will be taken care of by this
    fi

    if [ "${TAGONLY}" != "YES" ]; then
        echo $VERSION > version
        git add version > /dev/null 2>&1
        git commit -m "Updated to version $VERSION" > /dev/null 2>&1
        PUSH_COMMIT=${PUSH_COMMIT-YES}  # could have been set by legacy mode
    else
        PUSH_COMMIT="NO"
    fi
    TAG_ARGS=()
    if [ "${ANNOTATE}" == "YES" ]; then
        TAG_ARGS=(-a -m "Release ${VERSION}")
    fi
    git tag "${TAG_ARGS[@]}" $VERSION > /dev/null
    if [ "${PUSH_COMMIT}" == "YES" ]; then
        git push ${REPO} ${BRANCH} > /dev/null 2>&1 || die "Cannot push commit to ${BRANCH}, try with -t"
    fi
    git push ${REPO} ${VERSION} > /dev/null 2>&1
    notify
    popd > /dev/null 2>&1
    if [ ! -z "$TEMP_DIR" ] && [ "$TEMP_DIR" == "/tmp/tmp.*" ]; then
	    rm -rf "$TEMP_DIR"
    fi
}

if [ "$PROMPT" == "YES" ]; then
    echo "Press return to proceed..."
    read x
fi
update_tag

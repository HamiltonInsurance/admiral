#!/bin/bash


function die
{
    echo -e "DIE: $1"
    exit 1
}

function usage
{
    echo
    echo "Usage: $APP [OPTIONAL]"
    echo "A shell script for reporting the current repo version."
    echo
    echo " -r, --repo    Full URL of repo to fetch (default is remote fetch)"
    echo " -m, --major   Major version to consider (default is latest tag, e.g. v1.0)"
}

while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -h|--help)
            usage
            exit
            ;;
        -r|--repo|-f|--fetch-repo)
            REPO="$2"
            shift # past argument
            ;;
        -m|--major)
            MAJOR="$2"
            shift # past argument            
            ;;
    esac
    shift # past argument or value
done

if [ -z "$REPO" ]; then
    REPO=$(git remote show upstream | grep Fetch | awk '{print $3;}')
fi

if [ -z "$MAJOR" ]; then    
    LATEST_VERSION=$(git ls-remote --tags --refs ${REPO} | grep "refs/tags/v[0-9]\+\.[0-9]\+\.[0-9]\+" | sort -t '/' -k 3 -V | tail -n1 | cut -d "/" -f 3)
else
    echo $MAJOR | grep "v[0-9]\+\.[0-9]\+" 2>&1 > /dev/null|| die "bad major version format: $MAJOR"
    LATEST_VERSION=$(git ls-remote --tags --refs ${REPO} | grep "refs/tags/${MAJOR}\.[0-9]\+" | sort -t '/' -k 3 -V | tail -n1 | cut -d "/" -f 3)
fi    

echo $LATEST_VERSION

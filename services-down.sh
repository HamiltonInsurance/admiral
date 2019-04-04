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
    echo "A shell script for checking that all containers are up and running"
    echo
    echo "Optional:"
    echo " -v, --verbose       Displays the services that are running in a verbose mode"

}


while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -h|--help)
            usage
            exit
            ;;
        -v|--verbose)
            VERBOSE="YES"
            ;;
    esac
    shift
done

function headline() {
    MESSAGE=$1
    echo "${MESSAGE}"
    echo "${MESSAGE}" | sed "s/./=/g"
    echo ""
}

function verbose() {
    GLOBAL_SERVICES=$(echo "${SERVICES_NOT_RUNNING}" | grep global)
    REPLICATED_SERVICES=$(echo "${SERVICES_NOT_RUNNING}" | grep replicated)
    OTHER_SERVICES=$(echo "${SERVICES_NOT_RUNNING}" | grep -v replicated | grep -v global)

    echo ""
    
    if [ ! -z "${GLOBAL_SERVICES}" ]; then
        headline "The following global services are down"
        echo "${GLOBAL_SERVICES}"
        echo ""
    fi
    
    if [ ! -z "${REPLICATED_SERVICES}" ]; then
        headline "The following replicated services are down"
        echo "${REPLICATED_SERVICES}"
        echo ""
    fi
    
    if [ ! -z "${OTHER_SERVICES}" ]; then
        headline "The following other services are down"
        echo "${OTHER_SERVICES}"
        echo ""
    fi
}

SERVICES_NOT_RUNNING=$(docker service ls | grep "\s0/[0-9]\+\s" | awk '{print $2, $3}')

if [ -z "${SERVICES_NOT_RUNNING}" ]; then
    exit 0
elif [ "${VERBOSE}" == "YES" ]; then
    verbose
else
    echo "${SERVICES_NOT_RUNNING}"
fi

exit 1

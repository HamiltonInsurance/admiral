#!/bin/bash

function die
{
    echo -e "DIE: $1"
    exit 1
}

function usage
{
    echo
    echo "Usage: $APP [OPTIONS] CMD"
    echo "A shell script for running commands on other machines."
    echo
    echo " CMD              Run a command on all matching machines"
    echo
    echo "Options:"
    echo
    echo " -m, --machine    A machine to consider, otherwise all hosts are queried"
    echo " -x, --max-number Maximum number of machines to iterate through"
    echo " -n, --number     Check a machine by number"
    echo " -p, --prefix     Use a different prefix to the one in the environment"
    echo " -s, --suffix     Use a different suffix to the one in the environment"
    echo " -u, --user       Specify user to run command (default: whoami)"
    echo " -v, --verbose    Lots of output"
}

MACHINE=
NUMBER=
CMD=
CMD_USER=$(whoami)
STDOUT=/dev/null

while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -h|--help)
            usage
            exit
            ;;
        -m|--machine)
            MACHINE="$2"
            shift # past argument
            ;;
        -x|--max-number)
            MAX_MACHINES=$(printf "%02d" "$2")
            shift # past argument
            ;;
        -n|--number)
            NUMBER=$(printf "%02d" "$2")
            shift # past argument
            ;;
        -s|--suffix)
            MACHINE_NAME_SUFFIX="$2"
            shift # past argument
            ;;
        -p|--prefix)
            MACHINE_NAME_PREFIX="$2"
            shift # past argument
            ;;
        -u|--user)
            CMD_USER="$2"
            shift # past argument
            ;;
        -v|--verbose)
            STDOUT="/dev/stdout"
            ;;        
        *)
            CMD="$key"
            ;;
    esac
    shift # past argument or value
done

if [ -z "$CMD" ]; then
    die "no command specified"
fi

if [ -n "$NUMBER" ]; then    
    MACHINE=$MACHINE_NAME_PREFIX$NUMBER
fi

function run_cmd
{
    local MACHINE=$1
    if ! nslookup $MACHINE > /dev/null 2>&1; then
        echo "$MACHINE: <does not exist>"
    elif ping -c 1 $MACHINE > /dev/null 2>&1; then
        if [ -z "${CMD_USER}" ]; then
            RESULT=$(/usr/bin/ssh $MACHINE -tt "${CMD} 2> ${STDOUT}" 2> ${STDOUT})
        else
            RESULT=$(sudo -u ${CMD_USER} /usr/bin/ssh $MACHINE -tt "${CMD} 2> ${STDOUT}" 2> ${STDOUT})
        fi
        if [ -z "$RESULT" ]; then
            RESULT="<none>"
        fi
        echo "$MACHINE: $RESULT"
    else
        echo "$MACHINE: <not reachable>"
        
    fi
}

if [ -n "$MACHINE" ]; then
    run_cmd $MACHINE
else    
    for M in $(seq -w $MAX_MACHINES); do
        run_cmd ${MACHINE_NAME_PREFIX}$M${MACHINE_NAME_SUFFIX}
    done
fi

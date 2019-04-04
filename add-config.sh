#!/bin/bash
if valenv GIT_HOST CONFIG_REPO; then exit 1; fi
VALUE=$2
if [ -z "${KEY}" ]; then
    echo "A name for the config item must be supplied"
    exit 1
fi
if [ -n "$(echo ${KEY} | sed 's/[0-9A-Za-z_-]//g')" ]; then
    echo "A key must contain only alphanumeric, underscore or hyphen characters" 
    exit 1
fi
WORK_DIR=$(mktemp -d)
pushd ${WORK_DIR}
git clone ${GIT_HOST}/${CONFIG_REPO}.git
cd config/
echo "${VALUE}" > ${KEY}
git add ${KEY}
git commit -m "added ${KEY}"
git push origin HEAD
if [[ "${WORK_DIR}" == /tmp/* ]]; then
    rm -rf "${WORK_DIR}"
fi
cd
cd config
git pull
popd

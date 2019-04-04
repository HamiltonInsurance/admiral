#!/bin/bash

# A script for setting up a host to run docker

function die
{
	echo -e "DIE: $1"
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
	echo "Usage: $APP [OWNER] [OPTIONAL]"
	echo "Configure a host to run containers."
	echo
	echo "Optional:"
	echo "OWNER                    Username of the machine owner"
	echo " -l, --location    PATH  Location of config (e.g. //foo/bar)"
	echo " -u, --user        NAME  Name of the config user"
	echo " -p, --pass        PASS  Password of the config user"
	echo " -n, --name        NAME  Supply a registered DNS hostname for the host"
	echo " -e, --email       NAME  Supply an email address for master of the watch slack notifications and git setup"
	echo " -k, --public-key  KEY   Supply a public key if setting up an account"
	echo " --force-config          Always download config"
}

# defaults
SHELL=/bin/bash
HOST_OWNER_FILE="/etc/owner"
APP=$0
HOSTCONFIG_APP=$(basename $0)
HOSTNAME=$(hostname)
FORCE_CONFIG=no
OWNER=$(cat ${HOST_OWNER_FILE} 2>&-)
if [ -z "$OWNER" ]; then
	OWNER=admiral
fi
CONFIG_LOCATION=
CONFIG_USER=
CONFIG_PASS=
IP_ADDR=
SLACK_NAME=
GIT_NAME=
EMAIL=
PUBLIC_KEY=
HOSTNAME_SET="no"

while [[ $# -gt 0 ]]
do
	key="$1"
	case $key in
		-h|--help)
			usage
			exit
			;;
		-l|--location)
			CONFIG_LOCATION="$2"
			shift # past argument
			;;
		-u|--config-user)
			CONFIG_USER="$2"
			shift # past argument
			;;
		-p|--config-pass)
			CONFIG_PASS="$2"
			shift # past argument
			;;
		-k|--public-key)
			PUBLIC_KEY="$2"
			shift # past argument
			;;
		-n|--name)
			HOSTNAME="$2"
			HOSTNAME_SET="yes"
			shift # past argument
			;;
		-e|--email)
			EMAIL="$2"
			SLACK_NAME="$(echo $EMAIL | sed "s/@.*//")"
			GIT_NAME="$(echo ${SLACK_NAME} | sed "s/\./ /g" | sed "s/^./\U\0/" | sed "s/ ./\U\0/g")"
			shift # past argument
			;;
		--force-config)
			FORCE_CONFIG="yes"
			;;
		*)
			OWNER="$key"
			;;

	esac
	shift # past argument or value
done

if ! valenv GIT_HOST CONFIG_REPO DEPLOY_REPO CONFIG_DIR DOCKER_DNS DNS_DOMAIN DNS_SERVER_IP; then exit 1; fi

ADMIRAL_DIR=/home/${OWNER}
echo -n ${OWNER} > ${HOST_OWNER_FILE}
LOCAL_MOUNT_POINT=${CONFIG_DIR}
CONFIG_DIR=${ADMIRAL_DIR}/config
APPS_DIR=${ADMIRAL_DIR}/deploy

function check_git_access
{
	REPOS="${CONFIG_REPO} ${DEPLOY_REPO}"
	for REPO in ${REPOS}; do
		su -s /bin/bash -c "git ls-remote ${GIT_HOST}/${REPO}.git" ${OWNER} > /dev/null 2>&1
		if [ "$?" != "0" ]; then
			cat ${ADMIRAL_DIR}/.ssh/id_rsa.pub
			die "unable to access ${GIT_HOST}, please enable ssh key access with the above on ${REPO} "
		fi
	done
}

function add_config_mount
{
	if [ -z "$CONFIG_LOCATION" ]; then
		CONFIG_LOCATION=$CONFIG_DIR
		BIND="none bind"
	else
		LOCAL_USER="user=${CONFIG_USER},"
		LOCAL_PASS="password=${CONFIG_PASS},"
		BIND="cifs ${LOCAL_USER}${LOCAL_PASS}iocharset=utf8,sec=ntlm,dir_mode=0555,file_mode=0444,vers=1.0"
	fi
	mkdir -p ${LOCAL_MNT_POINT}
	if ! grep ${LOCAL_MNT_POINT} /etc/fstab > /dev/null; then
		echo "Config: ${CONFIG_LOCATION}"
		echo -e "\n${CONFIG_LOCATION} ${LOCAL_MNT_POINT} ${BIND}" >> /etc/fstab
		mount ${LOCAL_MNT_POINT} || die "unable to mount ${LOCAL_MNT_POINT}, check /etc/fstab"
	fi
}

function add_packages
{
	PACKAGES="docker-ce cifs-utils jq rsyslog tmux emacs vim silversearcher-ag git"
	if ! dpkg -s ${PACKAGES} > /dev/null 2>&1; then
		echo "Installing necessary packages, please wait..."
		apt-get update > /dev/null || die "unable to apt-get update"
		apt-get -y install ${PACKAGES} > /dev/null || die "unable to install"
	fi
}

function check_admiral_user
{
	id -u admiral > /dev/null
	if [ $? -gt 0 ]; then
		die "admiral user does not exist, check your ubuntu image"
	fi
}

function check_owner_user
{
	id -u $OWNER > /dev/null
	if [ $? -gt 0 ]; then
			useradd -s /bin/bash -m $OWNER
			echo $OWNER:$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1) | chpasswd
			usermod -a -G docker $OWNER
			usermod -a -G nopswd $OWNER
			pushd /home/$OWNER > /dev/null 2>&1
			mkdir .ssh
			chmod 700 .ssh
			chown $OWNER:$OWNER .ssh
			cd .ssh > /dev/null 2>&1
			ssh-keygen -t rsa -N "" -f id_rsa
			echo "Add key to bit bucker user profile"
			cat id_rsa.pub
			wait
			chmod 400 *
			touch authorized_keys
			if [ ! -z "$PUBLIC_KEY" ]; then
				echo $PUBLIC_KEY >> authorized_keys
			fi
			chmod 600 authorized_keys
			chown $OWNER:$OWNER *
			popd > /dev/null 2>&1
	fi
}

function add_config
{
	if [ ! -e ${CONFIG_DIR} ]; then
		FORCE_CONFIG=yes
	fi

	if [ "${FORCE_CONFIG}" == "yes" ]; then
		if [ ! -e ${CONFIG_DIR} ]; then
			echo "Cloning dev config..."
			su -s /bin/bash -c "git clone $GIT_HOST/${CONFIG_REPO}.git ${CONFIG_DIR} > /dev/null 2>&1" ${OWNER} || die "unable to clone config"
		else
			echo "Updating dev config..."
			su -s /bin/bash -c "cd ${CONFIG_DIR} && git pull > /dev/null 2>&1" ${OWNER} || die "unable to pull config"
		fi
	else
		pushd ${CONFIG_DIR} 2>&1 > /dev/null
		su -s /bin/bash -c "git pull > /dev/null 2>&1" ${OWNER} || echo "unable to pull config"
		if [ -e "${CONFIG_DIR}/stack-name-override" ]; then
			if [ -e "${CONFIG_DIR}/stack-name" ]; then
				rm "${CONFIG_DIR}/stack-name"
			fi
			ln -s ${CONFIG_DIR}/stack-name-override ${CONFIG_DIR}/stack-name
		else
			echo -n "${OWNER}" > ${CONFIG_DIR}/stack-name
		fi
		popd 2>&1 > /dev/null
	fi

	if [ ! -e ${CONFIG_DIR}/authorized-keys ]; then
	ln -s /home/$OWNER/.ssh/authorized_keys ${CONFIG_DIR}/authorized-keys
	fi
}

function configure_notification
{
	if [ ! -z "$EMAIL" ]; then
		if [ ! -z "${SLACK_NAME}" ]; then
			echo ${SLACK_NAME} > ${CONFIG_DIR}/slack-channel-mow
		fi
		if [ ! -z "${GIT_NAME}" ]; then
			su -s /bin/bash -c "git config --global user.name \"${GIT_NAME}\"" ${OWNER} || echo "unable to configure git username"
			su -s /bin/bash -c "git config --global user.email \"${EMAIL}\"" ${OWNER} || echo "unable to configure git email"
		fi
	fi
}

function add_apps
{
	if [ ! -e $APPS_DIR ]; then
		echo "Cloning deploy..."
		su -s /bin/bash -c "git clone $GIT_HOST/${DEPLOY_REPO}.git ${APPS_DIR} > /dev/null 2>&1" ${OWNER} || die "unable to clone deploy"
	else
		su -s /bin/bash -c "cp ${APPS_DIR}/docker/$HOSTCONFIG_APP.sh ${APPS_DIR}/docker/$HOSTCONFIG_APP.old" ${OWNER}
		echo "Updating deploy..."
		su -s /bin/bash -c "cd ${APPS_DIR} && git pull > /dev/null 2>&1" ${OWNER} || die "unable to update deploy"
	fi

	for LOCAL_APP in valenv docker-cleanup py-update fleet admiral hostconfig bootstrap sail bump version owners tt sea-lord add-config services-down; do
		rm -f /usr/local/bin/${LOCAL_APP}
		ln -s ${APPS_DIR}/docker/${LOCAL_APP}.sh /usr/local/bin/${LOCAL_APP}
	done
}

function add_fstab
{
	if ! cat ${ADMIRAL_DIR}/config/host-fstab | grep -f /etc/fstab > /dev/null; then
		echo "Populating fstab..."
		cat ${ADMIRAL_DIR}/config/host-fstab | sed "s/admiral/$OWNER/g" >> /etc/fstab
		for D in $(cat ${ADMIRAL_DIR}/config/host-fstab | awk '{print $2;}'); do
			mkdir -p $D
		done
		mount -a || die "unable to mount all, check /etc/fstab"
	fi
}

function add_rsyslog
{
	echo "Configuring rsyslog..."
	cp ${ADMIRAL_DIR}/config/host-rsyslogd /etc/rsyslog.d/30-docker.conf
	/etc/init.d/rsyslog restart > /dev/null
}

function add_docker_dns
{
	echo "Configuring docker DNS..."
	# force the DNS to work within a swarm
	# using the internal network settings
	echo $DOCKER_DNS > /etc/docker/daemon.json
}
function add_filebeat_directory
{
	echo "Creating filebeat directory..."
	mkdir -p /etc/filebeat
        # filebeat container doesn't run as root so it can't write unless we make this read/write
        chmod a+rw /etc/filebeat
}

function configure_log_access
{
	touch /var/log/docker_combined.log
	chown syslog:adm /var/log/docker_combined.log
}

function maybe_add_network
{
	if [ "$HOSTNAME_SET" == "no" ]; then
		return
	fi
	COUNT=$(nslookup ${HOSTNAME} | grep -A 1 Name | wc -l)
	if [ "$COUNT" != "2" ]; then
		die "unexpected number of DNS names for ${HOSTNAME}, check your network config"
	fi

	# write the hostname
	echo ${HOSTNAME} > /etc/hostname

	# write the hosts file
	cat <<EOF > /etc/hosts
127.0.0.1    localhost

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

	# write the netplan
	ADDR=$(nslookup ${HOSTNAME} | grep -A 1 Name | tail -n1 | cut -f2 -d" ")
	GW="$(echo $ADDR | cut -f1-3 -d.).1"
	cat <<EOF > /etc/netplan/01-netcfg.yaml
# This file describes the network interfaces available on your system
# For more information, see netplan(5).
network:
  version: 2
  renderer: networkd
  ethernets:
	ens160:
      dhcp4: no
      dhcp6: no
      addresses: [$ADDR/24]
      gateway4: $GW
      nameservers:
		search: [$DNS_DOMAIN]
		addresses: [$DNS_SERVER_IP]
EOF
	netplan apply

	echo
	echo "-- NETWORK CHANGED (${HOSTNAME}) --"
	echo
	echo "Rebooting in 10 sec..."
	sleep 10
	shutdown -r now
	exit 0
}

# Make sure only root can run our script
if [[ $EUID -ne 0 ]]; then
	die "This script must be run as root"
fi

echo "Configuring ${HOSTNAME} for ${OWNER}..."

maybe_add_network
add_packages
check_admiral_user
check_owner_user
check_git_access
add_config
add_config_mount
add_apps
add_fstab
add_rsyslog
add_docker_dns
add_filebeat_directory
configure_log_access
configure_notification

# check if this script itself changed
if ! su -s /bin/bash -c "diff ${APPS_DIR}/docker/$HOSTCONFIG_APP.sh ${APPS_DIR}/docker/$HOSTCONFIG_APP.old > /dev/null 2>&1" ${OWNER}; then
	echo "hostconfig change detected, re-running..."
	hostconfig ${OWNER}
else
	echo "$HOSTNAME configured"
fi

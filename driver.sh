#!/bin/sh --
#
# Driver for distributed JMeter testing.
#
# This script will 
#   i.  Create a Docker container each for the specified number 
#       of JMeter servers.
#  ii.  Create a Docker container for the JMeter client (master).
#       The client will connect to the servers created in step 
#       (i) and trigger the test script that is provided.
#        Tips -- Look for the following in the client logs
# 
# TODO: Cleanup - Not a biggie.  Just watiting on shutdown to be done.

#
# The environment
SERVER_IMAGE=ssankara/jmeter-server
CLIENT_IMAGE=ssankara/jmeter
DATADIR=
JMX_SCRIPT=
WORK_DIR=$(readlink -f /tmp)
NUM_SERVERS=1
HOST_WRITE_PORT=49500
HOST_READ_PORT=49501
# Name of the JMeter client container
CLIENT_NAME=jmeter-client
# Prefix of all JMeter server containers.  Actual name will be PREFIX-#
SERVER_NAME_PREFIX=jmeter-server
JTL_FILE=jtl.jtl

function validate_env() {
	if [[ ! -d ${WORK_DIR} ]] ; then
	  echo "The working directory '${WORK_DIR}' does not exist"
		usage
		exit 1
	fi
	if [[ ! -d ${DATADIR} ]] ; then
	  echo "The data directory '${DATADIR}' does not exist"
		usage
		exit 2
	fi
	if [[ ! -f ${JMX_SCRIPT} ]] ; then
	  echo "The script file '${JMX_SCRIPT}' does not exist"
		usage
		exit 3
	fi
	if [[ ${NUM_SERVERS} -lt 1 ]]; then
		echo "Must start at least 1 JMX server."
		usage
		exit 4
	fi
}

function display_env() {
	echo "    DATADIR=${DATADIR}"
	echo " JMX_SCRIPT=${JMX_SCRIPT}"
	echo "   WORK_DIR=${WORK_DIR}"
	echo "NUM_SERVERS=${NUM_SERVERS}"
}

function start_servers() {
	n=1
	while [[ ${n} -le ${NUM_SERVERS} ]]
	do
		# Create a log directory for the server
		LOGDIR=${WORK_DIR}/logs/${n}
	  mkdir -p ${LOGDIR}
	
		# Start the server container
		docker run --cidfile ${LOGDIR}/cid \
					-d \
					-p 0.0.0.0:${HOST_READ_PORT}:1099 \
					-p 0.0.0.0:${HOST_WRITE_PORT}:60000 \
					-v ${LOGDIR}:/logs \
					-v ${DATADIR}:/input_data \
					--name jmeter-server-${n} \
					${SERVER_IMAGE} 1>/dev/null 2>&1
		err=$?
		if [[ ${err} -ne 0 ]] ; then
			echo "Error '${err}' while starting a jmeter server. Quitting"
			exit ${err}
		fi

		# Prepare for next server
	  n=$((${n} + 1))
		HOST_READ_PORT=$((${HOST_READ_PORT} +  2))
		HOST_WRITE_PORT=$((${HOST_WRITE_PORT} + 2))
	done
}

function server_ips() {
	#
	# CAUTION: The logic here assumes that we want to use all 
	# active jmeter servers.
	for pid in $(docker ps | grep ${SERVER_IMAGE} | awk '{print $1}')
	do
	
	  # Get the IP for the current pid
	  x=$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' ${pid})
	
		# Append to SERVER_IPS
		if [[ ! -z "${SERVER_IPS}" ]]; then
			SERVER_IPS=${SERVER_IPS},
		fi
		SERVER_IPS=${SERVER_IPS}$x
	done
}

#
# Get confirmation
function confirm() {
	echo "Here's what we've got..."
	echo "---------------------------------"
	display_env
	echo "---------------------------------"
	read -n 1 -e -p "Does this look OK?y/[n]: " yesno
	case ${yesno} in
		y) return ;;
		n) exit 6;;
	esac
}

#
# Wait for client to terminate
function wait_for_client() {
	echo "Checking on JMeter client status every 30 secs..."
	CLIENT_CID=$(cat ${LOGDIR}/cid)

	# Wait for client CID to clear
	while :
	do
		docker ps --no-trunc | grep ${CLIENT_CID} 2>/dev/null 1>&2
		if [[ $? -ne 0 ]]; then
			echo
			echo "JMeter client done"
			break
		fi
		echo -n "."
		sleep 30
	done
}

#
# Stop servers
function stop_servers() {
	echo "Stopping all (${NUM_SERVERS}) JMeter servers..."
  n=1
	while [[ ${n} -le ${NUM_SERVERS} ]]
	do
		docker stop ${SERVER_NAME_PREFIX}-${n}
		n=$((${n}+1))
	done
	
}

#
# Remove all stopped containers
function remove_containers() {
	echo "Removing containers..."
	docker rm ${CLIENT_NAME}
	n=1
	while [[ ${n} -le ${NUM_SERVERS} ]]
	do
		docker rm ${SERVER_NAME_PREFIX}-${n}
		n=$((${n}+1))
	done
}

#
# Le usage
function usage() {
  echo "Usage: $0 [-d data-dir] [-n num-jmeter-servers] [-s jmx] [-w work-dir]"
	echo "-d      The data directory for data files used by the JMX script."
	echo "-h      This help message"
	echo "-n      The required number of servers"
	echo "-s      The JMX script file"
	echo "-w      The working directory. Logs are relative to it."
}

# ------------- Show starts here -------------

#
# Getopts to read - datadir, WORK_DIR, count of servers, script dir
# script -d data-dir -s script-dir -w work-dir -n num-servers
while getopts :d:hn:s:w: opt
do
	case ${opt} in
		d) DATADIR=$(readlink -f ${OPTARG}) ;;
		h) usage && exit 0 ;;
		n) NUM_SERVERS=${OPTARG} ;;
		s) JMX_SCRIPT=$(readlink -f ${OPTARG}) ;;
		w) WORK_DIR=$(readlink -f ${OPTARG}) ;;
		:) echo "The -${OPTARG} option requires a parameter"
			 exit 1 ;;
		?) echo "Invalid option: -${OPTARG}"
			 exit 1 ;;
	esac
done
shift $((OPTIND -1))

#
# Validate environment
validate_env

#
# Make sure the user is satisfied with the settings
confirm

#
# Set a working directory
#  - It will be the specified-work-dir/current-process-id
cd ${WORK_DIR}
if [[ -d $$ ]]
then
	echo "Work directory (${WORK_DIR}/$$) already exists.  Quitting."
	exit 7
fi
mkdir $$
WORK_DIR=${WORK_DIR}/$$

#
# Create a place for all the log files
mkdir -p ${WORK_DIR}/logs

# Start the specified number of jmeter-server containers
echo "Starting servers..."
start_servers

#
# Get the IP addresses for the servers
SERVER_IPS=
server_ips
echo "Server IPs are: ${SERVER_IPS}"
# SERVER_IPS will now be string of the form 1.2.3.4,9.8.7.6

#
# Start the jmeter (client) container and connect to the servers
echo "Starting client..."
LOGDIR=${WORK_DIR}/logs/client
mkdir -p ${LOGDIR}
docker run --cidfile ${LOGDIR}/cid \
				-d \
				-v ${LOGDIR}:/logs \
				-v ${DATADIR}:/input_data \
				-v $(dirname ${JMX_SCRIPT}):/scripts \
				--name jmeter-client \
				${CLIENT_IMAGE} -n -t /scripts/$(basename ${JMX_SCRIPT}) -l /logs/${JTL_FILE} -LDEBUG -R${SERVER_IPS}

# Shutdown the client
wait_for_client

# Shutdown the servers
stop_servers

# Clean up
remove_containers

echo "Please see ${LOGDIR}/${JTL_FILE} for the results of the run"

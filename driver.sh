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
#  TODO: Shutdown
#        Tips -- Look for the following in the client logs
# 
#          INFO - Shutdown hook started
#          DEBUG - jmeter.reporters.ResultCollector: Flushing: /logs/jtl.jtl
#          INFO  - jmeter.reporters.ResultCollector: Shutdown hook ended
#
#        Note the assumed log level for this recipe to work.
# TODO: Cleanup - Not a biggie.  Just watiting on shutdown to be done.
# TODO: Allow image names to be specified on the command line.
# TODO: Rewrite this whole thing in golang

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
# Set a working directory.
cd ${WORK_DIR}

#
# Create a place for all the log files
if [[ -d ${WORK_DIR}/logs ]] ; then
	if [[ -d ${WORK_DIR}/logs.bak ]] ; then
		echo "Unable to backup existing logs dir (backup dir exists)."
		exit 5
	else
		mv ${WORK_DIR}/logs ${WORK_DIR}/logs.bak
	fi
fi
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
				${CLIENT_IMAGE} -n -t /scripts/$(basename ${JMX_SCRIPT}) -l /logs/jtl.jtl -LDEBUG -R${SERVER_IPS}

# TODO Client must somehow notify host of job completion

# TODO Shutdown the client

# TODO Shutdown the servers

# TODO Clean up dirs

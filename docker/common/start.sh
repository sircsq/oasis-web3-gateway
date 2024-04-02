#!/usr/bin/env bash

# This script spins up local oasis stack by running the spinup-oasis-stack.sh,
# starts the web3 gateway on top of it, and deposits to a test account on the
# ParaTime.
# Mandatory ENV Variables:
# - all ENV variables required by spinup-oasis-stack.sh
# - OASIS_WEB3_GATEWAY: path to oasis-web3-gateway binary
# - OASIS_WEB3_GATEWAY_CONFIG_FILE: path to oasis-web3-gateway config file
# - OASIS_DEPOSIT: path to oasis-deposit binary
# - BEACON_BACKEND: beacon epoch transition mode 'mock' (default) or 'default'
# - OASIS_SINGLE_COMPUTE_NODE: (default: true) if non-empty only run a single compute node

set -euo pipefail

export OASIS_NODE_LOG_LEVEL=${OASIS_NODE_LOG_LEVEL:-warn}

export OASIS_DOCKER_USE_TIMESTAMPS_IN_NOTICES=${OASIS_DOCKER_USE_TIMESTAMPS_IN_NOTICES:-no}

export OASIS_DOCKER_DEBUG_DISK_AND_CPU_USAGE=${OASIS_DOCKER_DEBUG_DISK_AND_CPU_USAGE:-no}

export OASIS_SINGLE_COMPUTE_NODE=${OASIS_SINGLE_COMPUTE_NODE-1}
OASIS_WEB3_GATEWAY_VERSION=$(${OASIS_WEB3_GATEWAY} -v | head -n1 | cut -d " " -f 3 | sed -r 's/^v//')
OASIS_CORE_VERSION=$(${OASIS_NODE} -v | head -n1 | cut -d " " -f 3 | sed -r 's/^v//')
VERSION=$(cat /VERSION)
echo "${PARATIME_NAME}-localnet ${VERSION} (oasis-core: ${OASIS_CORE_VERSION}, ${PARATIME_NAME}-paratime: ${PARATIME_VERSION}, oasis-web3-gateway: ${OASIS_WEB3_GATEWAY_VERSION})"
echo

export BEACON_BACKEND=${BEACON_BACKEND:-mock}

OASIS_NODE_SOCKET=${OASIS_NODE_DATADIR}/net-runner/network/client-0/internal.sock
OASIS_KM_SOCKET=${OASIS_NODE_DATADIR}/net-runner/network/keymanager-0/internal.sock

OASIS_WEB3_GATEWAY_PID=""
OASIS_NODE_PID=""

function cleanup {
	if [[ -n "${OASIS_WEB3_GATEWAY_PID}" ]]; then
		kill -9 ${OASIS_WEB3_GATEWAY_PID}
	fi
	if [[ -n "${OASIS_NODE_PID}" ]]; then
		kill -9 ${OASIS_NODE_PID}
	fi
}

trap cleanup INT TERM EXIT

# If we have an interactive terminal, use colors.
if [[ -t 0 ]]; then
	GREEN="\e[32;1m"
	YELLOW="\e[33;1m"
	CYAN="\e[36;1m"
	OFF="\e[0m"
else
	GREEN=""
	YELLOW=""
	CYAN=""
	OFF=""
fi

if [[ "x${OASIS_DOCKER_USE_TIMESTAMPS_IN_NOTICES}" == "xyes" ]]; then
function notice {
	printf "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${OFF} $@"
}
else
function notice {
	printf "${CYAN} *${OFF} $@"
}
fi

T_START="$(date +%s)"

notice "Starting oasis-net-runner with ${CYAN}${PARATIME_NAME}${OFF}...\n"
/spinup-oasis-stack.sh --log.level ${OASIS_NODE_LOG_LEVEL} 2>1 &>/var/log/spinup-oasis-stack.log &
OASIS_NODE_PID=$!

notice "Waiting for Postgres to start"
su -c "POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres /usr/local/bin/docker-entrypoint.sh postgres &" postgres 2>1 &>/var/log/postgres.log
function is_postgres_ready() {
	pg_isready -h 127.0.0.1 -p 5432 2>1 &>/dev/null
}
until is_postgres_ready; do echo -n .; sleep 1; done
echo

notice "Waiting for Oasis node to start..."
# Wait for oasis-node socket before starting web3 gateway.
while [[ ! -S ${OASIS_NODE_SOCKET} ]]; do echo -n .; sleep 1; done
echo

# Fixes permissions so oasis-web3-gateway tests can be run
# While /serverdir/node is bind-mounted to /tmp/eth-runtime-test
chmod 755 /serverdir/node/net-runner/
chmod 755 /serverdir/node/net-runner/network/
chmod 755 /serverdir/node/net-runner/network/client-0/
chmod a+rw /serverdir/node/net-runner/network/client-0/internal.sock

notice "Starting oasis-web3-gateway...\n"
${OASIS_WEB3_GATEWAY} --config ${OASIS_WEB3_GATEWAY_CONFIG_FILE} 2>1 &>/var/log/oasis-web3-gateway.log &
OASIS_WEB3_GATEWAY_PID=$!

# Wait for compute nodes before initiating deposit.
notice "Bootstrapping network (this might take a minute)"
if [[ ${BEACON_BACKEND} == 'mock' ]]; then
	echo -n .
	${OASIS_NODE} debug control wait-nodes -n 2 -a unix:${OASIS_NODE_SOCKET}

	echo -n .
	${OASIS_NODE} debug control set-epoch --epoch 1 -a unix:${OASIS_NODE_SOCKET}

	# Transition to the final epoch when the KM generates ephemeral secret.
	if [[ ${PARATIME_NAME} == 'sapphire' ]]; then
		while (${OASIS_NODE} control status -a unix:${OASIS_KM_SOCKET} | jq -e ".keymanager.worker.ephemeral_secrets.last_generated_epoch!=2" >/dev/null); do
			sleep 0.5
		done
	fi

	echo -n .
	${OASIS_NODE} debug control set-epoch --epoch 2 -a unix:${OASIS_NODE_SOCKET}
else
	echo -n ...
	${OASIS_NODE} debug control wait-ready -a unix:${OASIS_NODE_SOCKET}
fi
echo

if [[ ${PARATIME_NAME} == 'sapphire' ]]; then
	notice "Waiting for key manager..."
	function is_km_ready() {
		curl -X POST -s \
		  -H 'Content-Type: application/json' \
		  --data '{"jsonrpc":"2.0","method":"oasis_callDataPublicKey","params":[],"id":1}' \
		  http://127.0.0.1:8545 2>1 | jq -e '.result | has("key")' 2>1 &>/dev/null
	}
	until is_km_ready; do
		if [[ ${BEACON_BACKEND} == 'mock' ]]; then
			epoch=`${OASIS_NODE} control status -a unix:${OASIS_NODE_SOCKET} | jq '.consensus.latest_epoch'`
			epoch=$((epoch + 1))
			${OASIS_NODE} debug control set-epoch --epoch $epoch -a unix:${OASIS_NODE_SOCKET}
		fi

		echo -n .
		sleep 1
	done
	echo
fi

notice "Populating accounts...\n\n"
${OASIS_DEPOSIT} -sock unix:${OASIS_NODE_SOCKET} "$@"

T_END="$(date +%s)"

echo
printf "${YELLOW}WARNING: The chain is running in ephemeral mode. State will be lost after restart!${OFF}\n\n"
notice "Listening on ${CYAN}http://localhost:8545${OFF} and ${CYAN}ws://localhost:8546${OFF}. Chain ID: ${GATEWAY__CHAIN_ID}\n"
notice "Container start-up took ${CYAN}$((T_END-T_START))${OFF} seconds, node log level is set to ${CYAN}${OASIS_NODE_LOG_LEVEL}${OFF}.\n"

if [[ "x${OASIS_DOCKER_DEBUG_DISK_AND_CPU_USAGE}" == "xyes" ]]; then
	# When debugging disk and CPU usage, we terminate the container
	# after 60 minutes.
	QUIT_AFTER_N_REPORTS=6
	NUM_REPORTS=0

	# Also print a header for the readings below.
	echo
	echo "Uptime [minutes],Total node dir size [kB],Size of node logs [kB],Percent usage by logs [%],Load average (1 min),Load average (5 min),Load average (15 min)"
fi

if [[ ${BEACON_BACKEND} == 'mock' ]]; then
	# Run background task to switch epochs every 10 minutes.
	while true; do
		if [[ "x${OASIS_DOCKER_DEBUG_DISK_AND_CPU_USAGE}" == "xyes" ]]; then
			LOADAVG=$(uptime | cut -d':' -f5 | tr -d ' ')
			TOTAL_NODE_DIR_SIZE_KB=$(du -sk /serverdir/node | cut -f1)
			TOTAL_NODE_LOGS_SIZE_KB=$(du -skc /serverdir/node/net-runner/network/*/*.log | tail -1 | cut -f1)
			LOGS_PCT=$(echo "scale=4; (${TOTAL_NODE_LOGS_SIZE_KB} / ${TOTAL_NODE_DIR_SIZE_KB}) * 100" | bc)

			echo "$((NUM_REPORTS * 10)),${TOTAL_NODE_DIR_SIZE_KB},${TOTAL_NODE_LOGS_SIZE_KB},${LOGS_PCT},${LOADAVG}"

			if [[ ${NUM_REPORTS} -ge ${QUIT_AFTER_N_REPORTS} ]]; then
				exit 0
			fi
			NUM_REPORTS=$((NUM_REPORTS + 1))
		fi

		sleep $((60*10))

		epoch=`${OASIS_NODE} control status -a unix:${OASIS_NODE_SOCKET} | jq '.consensus.latest_epoch'`
		epoch=$((epoch + 1))
		${OASIS_NODE} debug control set-epoch --epoch $epoch -a unix:${OASIS_NODE_SOCKET}
	done
else
	wait
fi

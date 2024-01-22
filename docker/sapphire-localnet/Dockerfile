# Build oasis-web3-gateway
FROM golang:1.21 AS oasis-web3-gateway

COPY . /go/oasis-web3-gateway
RUN cd oasis-web3-gateway && make && strip -S -x oasis-web3-gateway docker/common/oasis-deposit/oasis-deposit

# Build simple-keymanager
FROM ghcr.io/oasisprotocol/oasis-core-dev:stable-23.0.x AS oasis-core-dev

ENV OASIS_UNSAFE_SKIP_KM_POLICY=1
ENV OASIS_CLI_VERSION=0.7.1

RUN git clone https://github.com/oasisprotocol/oasis-core.git --branch stable/23.0.x --depth 1 \
	&& cd oasis-core/tests/runtimes/simple-keymanager \
	&& cargo build --release \
	&& cd ../../../../ \
	&& git clone https://github.com/oasisprotocol/cli.git --branch v${OASIS_CLI_VERSION} --depth 1 \
	&& cd cli \
	&& make CGO_ENABLED=0

# Build sapphire-localnet
FROM postgres:16-alpine
RUN apk add --no-cache bash gcompat libseccomp jq binutils \
	&& su -c "POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres /usr/local/bin/docker-entrypoint.sh postgres &" postgres

# Docker-specific variables
ENV OASIS_CORE_VERSION=23.0.9
ENV PARATIME_VERSION=0.7.0
ENV PARATIME_NAME=sapphire
ENV GATEWAY__CHAIN_ID=0x5afd

# start.sh and spinup-oasis-stack.sh ENV variables.
ENV OASIS_NODE=/oasis-node
ENV OASIS_NET_RUNNER=/oasis-net-runner
ENV OASIS_NODE_DATADIR=/serverdir/node
ENV OASIS_WEB3_GATEWAY=/oasis-web3-gateway
ENV OASIS_DEPOSIT=/oasis-deposit
ENV OASIS_WEB3_GATEWAY_CONFIG_FILE=/localnet.yml
ENV PARATIME=/runtime.elf
ENV KEYMANAGER_BINARY=/simple-keymanager
ENV OASIS_UNSAFE_SKIP_AVR_VERIFY=1
ENV OASIS_UNSAFE_SKIP_KM_POLICY=1
ENV OASIS_UNSAFE_ALLOW_DEBUG_ENCLAVES=1

ARG VERSION

# simple-keymanager
COPY --from=oasis-core-dev /oasis-core/target/release/simple-keymanager ${KEYMANAGER_BINARY}

# cli
COPY --from=oasis-core-dev /cli/oasis /oasis

# oasis-web3-gateway binary, config, spinup-* scripts and staking_genesis.json.
COPY --from=oasis-web3-gateway /go/oasis-web3-gateway/oasis-web3-gateway ${OASIS_WEB3_GATEWAY}
COPY --from=oasis-web3-gateway /go/oasis-web3-gateway/docker/common/oasis-deposit/oasis-deposit ${OASIS_DEPOSIT}
COPY docker/common/localnet.yml ${OASIS_WEB3_GATEWAY_CONFIG_FILE}
COPY docker/common/start.sh /
COPY tests/tools/* /

# Configure oasis-node and oasis-net-runner.
RUN wget --quiet "https://github.com/oasisprotocol/oasis-core/releases/download/v${OASIS_CORE_VERSION}/oasis_core_${OASIS_CORE_VERSION}_linux_amd64.tar.gz"  \
    && tar xfvz "oasis_core_${OASIS_CORE_VERSION}_linux_amd64.tar.gz" \
	&& mkdir -p "$(dirname ${OASIS_NODE})" "$(dirname ${OASIS_NET_RUNNER})" \
	&& mv "oasis_core_${OASIS_CORE_VERSION}_linux_amd64/oasis-node" "${OASIS_NODE}" \
	&& mv "oasis_core_${OASIS_CORE_VERSION}_linux_amd64/oasis-net-runner" "${OASIS_NET_RUNNER}" \
	&& rm "oasis_core_${OASIS_CORE_VERSION}_linux_amd64.tar.gz" \
	&& rm -rf "oasis_core_${OASIS_CORE_VERSION}_linux_amd64" \
	&& echo "" \
	&& echo "Configure the ParaTime." \
	&& mkdir -p "$(dirname ${PARATIME})" \
    && wget --quiet "https://github.com/oasisprotocol/${PARATIME_NAME}-paratime/releases/download/v${PARATIME_VERSION}/localnet-${PARATIME_NAME}-paratime.orc" -O "/paratime.orc" \
    && unzip "paratime.orc" \
    && chmod a+x "runtime.elf" \
	&& rm "paratime.orc" \
	&& echo "" \
	&& echo "Write VERSION information." \
	&& echo "${VERSION}" > /VERSION \
	&& strip -S -x ${OASIS_NET_RUNNER} ${OASIS_NODE} /oasis /simple-keymanager \
	&& echo "" \
	&& ls -l / \
	&& echo "" \
	&& echo "*** Oasis Node:" \
	&& ${OASIS_NODE} --version \
	&& echo "" \
	&& echo "*** Oasis CLI:" \
	&& /oasis --version \
	&& echo ""

# Web3 gateway http and ws ports.
EXPOSE 8545/tcp
EXPOSE 8546/tcp

USER root
ENTRYPOINT ["/start.sh"]
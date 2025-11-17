ARG OTP_VERSION

# Build the release
FROM docker.io/library/erlang:${OTP_VERSION} AS builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install thrift compiler
ARG THRIFT_VERSION
ARG TARGETARCH
RUN wget -q -O- "https://github.com/valitydev/thrift/releases/download/${THRIFT_VERSION}/thrift-${THRIFT_VERSION}-linux-${TARGETARCH}.tar.gz" \
    | tar -xvz -C /usr/local/bin/

# Copy sources
RUN mkdir /build
COPY . /build/

# Build the release
WORKDIR /build
RUN rebar3 compile && \
    rebar3 as prod release --all

# Make a runner image
FROM docker.io/library/erlang:${OTP_VERSION}-slim

ARG USER_NAME=apprunner
ARG USER_UID=1001
ARG USER_GID=$USER_UID

# Set env
ENV RELX_REPLACE_OS_VARS=true
ENV ERL_DIST_PORT=31337
ENV CHARSET=UTF-8
ENV LANG=C.UTF-8

COPY --from=builder /build/_build/prod/rel/ /opt/

# Setup user
RUN groupadd --gid ${USER_GID} ${USER_NAME} && \
    useradd --uid ${USER_UID} --gid ${USER_GID} -M ${USER_NAME} && \
    chown -R ${USER_UID}:${USER_GID} /opt

USER ${USER_NAME}

ENTRYPOINT []
CMD []

EXPOSE 8022

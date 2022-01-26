FROM docker.io/library/erlang:24.1.7.0 AS builder
ARG BUILDARCH
ARG THRIFT_VERSION=0.14.2.2
RUN wget -q -O- "https://github.com/valitydev/thrift/releases/download/${THRIFT_VERSION}/thrift-${THRIFT_VERSION}-linux-${BUILDARCH}.tar.gz" \
    | tar -xvz -C /usr/local/bin/
RUN mkdir /build
COPY . /build/
WORKDIR /build
RUN rebar3 compile
RUN rebar3 as prod release

# Keep in sync with Erlang/OTP version in build image
FROM docker.io/library/erlang:24.1.7.0-slim
ENV SERVICE=hellgate
ENV CHARSET=UTF-8
ENV LANG=C.UTF-8
COPY --from=builder /build/_build/prod/rel/${SERVICE} /opt/${SERVICE}
WORKDIR /opt/${SERVICE}
ENTRYPOINT []
CMD /opt/${SERVICE}/bin/${SERVICE} foreground
EXPOSE 8022

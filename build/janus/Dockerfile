# syntax=docker/dockerfile:1

# SPDX-FileCopyrightText: 2026 Travis Wichert
#
# SPDX-License-Identifier: AGPL-3.0-or-later

ARG UBUNTU_VERSION=24.04
ARG JANUS_VERSION=1.4.3
ARG JANUS_COMMIT=1f0b75cac1c9ad819ee4c2a905a2c65b00b82cde

FROM ubuntu:${UBUNTU_VERSION} AS builder
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /src

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates git pkg-config \
      autoconf automake libtool cmake meson ninja-build \
      libglib2.0-dev libjansson-dev libssl-dev zlib1g-dev \
      libmicrohttpd-dev libconfig-dev

# libnice 0.1.24
ARG LIBNICE_COMMIT=af62014d520ac09c8fe1974bda1b253114c68843
RUN git clone https://github.com/libnice/libnice.git /src/libnice \
 && git -C /src/libnice checkout --detach "$LIBNICE_COMMIT" \
 && test "$(git -C /src/libnice rev-parse HEAD)" = "$LIBNICE_COMMIT" \
 && meson setup /src/libnice/build /src/libnice \
      --prefix=/usr/local --libdir=lib --buildtype=release \
      -Ddefault_library=shared \
      -Dgupnp=disabled -Dgstreamer=disabled -Dexamples=disabled \
      -Dtests=disabled -Dgtk_doc=disabled -Dintrospection=disabled \
      -Dcrypto-library=openssl \
 && ninja -C /src/libnice/build \
 && ninja -C /src/libnice/build install

# libsrtp 2.8.1
ARG LIBSRTP_COMMIT=6ff02afa8d2dc3f2e8896af391d137c1c66ff6fa
RUN git clone https://github.com/cisco/libsrtp.git /src/libsrtp \
 && git -C /src/libsrtp checkout --detach "$LIBSRTP_COMMIT" \
 && test "$(git -C /src/libsrtp rev-parse HEAD)" = "$LIBSRTP_COMMIT" \
 && cd /src/libsrtp \
 && ./configure --prefix=/usr/local --libdir=/usr/local/lib \
      --enable-openssl --disable-pcap CFLAGS="-O2" \
 && make -j"$(nproc)" shared_library \
 && make install

# libwebsockets 4.3.10
ARG LIBWEBSOCKETS_COMMIT=2288cf200bc1c28680765bd4f07e437356106c2d
RUN git clone https://github.com/warmcat/libwebsockets.git /src/libwebsockets \
 && git -C /src/libwebsockets checkout --detach "$LIBWEBSOCKETS_COMMIT" \
 && test "$(git -C /src/libwebsockets rev-parse HEAD)" = "$LIBWEBSOCKETS_COMMIT" \
 && cmake -S /src/libwebsockets -B /src/libwebsockets/build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_C_FLAGS="-fPIC" \
      -DLWS_MAX_SMP=1 \
      -DLWS_WITHOUT_EXTENSIONS=OFF \
      -DLWS_WITHOUT_TESTAPPS=ON \
      -DLWS_WITHOUT_TEST_CLIENT=ON \
      -DLWS_WITHOUT_TEST_PING=ON \
      -DLWS_WITHOUT_TEST_SERVER=ON \
      -DLWS_WITH_STATIC=OFF \
      -DLWS_WITH_HTTP2=OFF \
      -DLWS_ROLE_RAW_FILE=OFF \
 && cmake --build /src/libwebsockets/build -j"$(nproc)" \
 && cmake --install /src/libwebsockets/build

# Janus 1.4.3
ARG JANUS_VERSION
ARG JANUS_COMMIT
# usrsctp — Janus needs it for data channels, which the signaling server requires.
ARG USRSCTP_COMMIT=c625e21950600460cb5c6075616eb1622df2b06a
RUN git clone https://github.com/sctplab/usrsctp.git /src/usrsctp \
 && git -C /src/usrsctp checkout --detach "$USRSCTP_COMMIT" \
 && test "$(git -C /src/usrsctp rev-parse HEAD)" = "$USRSCTP_COMMIT" \
 && cmake -S /src/usrsctp -B /src/usrsctp/build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -Dsctp_build_shared_lib=ON \
      -Dsctp_build_static_lib=OFF \
      -Dsctp_werror=OFF \
 && cmake --build /src/usrsctp/build -j"$(nproc)" \
 && cmake --install /src/usrsctp/build

RUN git clone https://github.com/meetecho/janus-gateway.git /src/janus \
 && git -C /src/janus checkout --detach "$JANUS_COMMIT" \
 && test "$(git -C /src/janus rev-parse HEAD)" = "$JANUS_COMMIT" \
 && test "$(git -C /src/janus tag --points-at HEAD | grep -Fxc "v${JANUS_VERSION}")" = "1" \
 && cd /src/janus \
 && sh autogen.sh \
 && PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
    CPPFLAGS=-I/usr/local/include \
    LDFLAGS=-L/usr/local/lib \
    ./configure --prefix=/opt/janus \
      --enable-rest \
      --enable-websockets \
      --enable-websockets-event-handler \
      --disable-rabbitmq --disable-mqtt --disable-nanomsg \
      --disable-unix-sockets \
      --disable-sample-event-handler --disable-rabbitmq-event-handler \
      --disable-mqtt-event-handler --disable-nanomsg-event-handler \
      --disable-gelf-event-handler --disable-json-logger \
      --enable-data-channels \
      --disable-post-processing \
      --disable-turn-rest-api \
      --disable-plugin-audiobridge --disable-plugin-duktape \
      --disable-plugin-echotest --disable-plugin-lua \
      --disable-plugin-recordplay --disable-plugin-sip \
      --disable-plugin-nosip --disable-plugin-streaming \
      --disable-plugin-textroom --disable-plugin-videocall \
      CFLAGS="-O2 -g0" \
 && make -j"$(nproc)" \
 && make install \
 && make configs

FROM ubuntu:${UBUNTU_VERSION} AS runtime
ARG JANUS_VERSION

LABEL org.opencontainers.image.title="ansible-role-mash-nextcloud-talk-hpb" \
      org.opencontainers.image.description="Janus MCU for Nextcloud Talk HPB" \
      org.opencontainers.image.licenses="AGPL-3.0" \
      org.opencontainers.image.version="${JANUS_VERSION}"

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl openssl passwd \
      libglib2.0-0t64 libjansson4 libssl3t64 \
      libconfig9 libmicrohttpd12t64 zlib1g

COPY --from=builder /usr/local/lib /usr/local/lib
COPY --from=builder /opt/janus /opt/janus
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN find /opt/janus /usr/local/lib \( -name '*.la' -o -name '*.a' \) -delete \
 && echo /usr/local/lib > /etc/ld.so.conf.d/janus.conf \
 && ldconfig \
 && groupadd --gid 10001 janus \
 && useradd --uid 10001 --gid 10001 \
      --home-dir /nonexistent --shell /usr/sbin/nologin janus

ENV HOME=/tmp
USER 10001:10001
WORKDIR /opt/janus
EXPOSE 8088 8188

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${JANUS_HTTP_PORT:-8088}/janus/info" >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/opt/janus/bin/janus", "-F", "/tmp/janus-config", "--full-trickle", "--disable-colors", "--log-stdout"]

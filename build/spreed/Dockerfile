# syntax=docker/dockerfile:1

# SPDX-FileCopyrightText: 2026 Travis Wichert
#
# SPDX-License-Identifier: AGPL-3.0-or-later

ARG GO_VERSION=1.26.8
ARG SPREED_VERSION=2.1.1
ARG SPREED_COMMIT=e7a8fb7aa9b99ad9f41e0e1793ce147ed36ecc62

FROM golang:${GO_VERSION}-alpine AS builder
ARG SPREED_VERSION
ARG SPREED_COMMIT
RUN apk add --no-cache ca-certificates git \
 && git clone --depth 1 --branch "v${SPREED_VERSION}" \
      https://github.com/strukturag/nextcloud-spreed-signaling.git /src \
 && test "$(git -C /src rev-parse HEAD)" = "${SPREED_COMMIT}"
WORKDIR /src
RUN CGO_ENABLED=0 go build -trimpath \
      -ldflags "-s -w -X main.version=${SPREED_VERSION}" \
      -o /out/nextcloud-spreed-signaling ./cmd/server/... \
 && mkdir -p /out/empty

FROM scratch AS runtime
ARG SPREED_VERSION
ARG SPREED_COMMIT

LABEL org.opencontainers.image.title="ansible-role-mash-nextcloud-talk-hpb-spreed" \
      org.opencontainers.image.description="Nextcloud Talk Spreed signaling server" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.version="${SPREED_VERSION}" \
      org.opencontainers.image.revision="${SPREED_COMMIT}"

COPY --from=builder /out/nextcloud-spreed-signaling /usr/bin/nextcloud-spreed-signaling
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /out/empty /tmp
COPY --from=builder /out/empty /etc/signaling

USER 1000:1000
EXPOSE 8081
STOPSIGNAL SIGUSR1
ENTRYPOINT ["/usr/bin/nextcloud-spreed-signaling"]

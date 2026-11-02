# SPDX-FileCopyrightText: 2026 Travis Wichert
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# HPB protocol test client, built from the upstream signaling repository.
# It is CI/molecule-only and is never published.
# Keep SIGNALING_VERSION in sync with nextcloud_talk_hpb_signaling_container_image_tag
# (the image tag omits the leading `v`).
ARG SIGNALING_VERSION=v2.1.1

FROM golang:1.25 AS builder
ARG SIGNALING_VERSION

RUN CGO_ENABLED=0 go install "github.com/strukturag/nextcloud-spreed-signaling/v2/cmd/client@${SIGNALING_VERSION}"

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /go/bin/client /usr/local/bin/client
ENTRYPOINT ["/usr/local/bin/client"]

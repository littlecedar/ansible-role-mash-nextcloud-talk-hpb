<!--
SPDX-FileCopyrightText: 2026 Travis Wichert

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Configuring Nextcloud Talk HPB

This role deploys a Nextcloud Talk high-performance backend (HPB) on one node:
the `nextcloud-spreed-signaling` server and the Janus MCU. The NATS message bus they
talk over is deployed by the `nats` role
([`ansible-role-mash-nats`](https://github.com/littlecedar/ansible-role-mash-nats)),
which must run before this one.

It does **not** deploy coturn or Traefik. Those two are operator-provided and are
referenced only through the contract described below.

## Contents

- [Requirements](#requirements)
- [Container images](#container-images)
- [Required variables](#required-variables)
- [Networks and subnets](#networks-and-subnets)
- [Secrets](#secrets)
- [External relay proxy (Traefik)](#external-relay-proxy-traefik)
- [External TURN server (coturn)](#external-turn-server-coturn)
- [Nextcloud wiring](#nextcloud-wiring)
- [Firewall](#firewall)
- [Operating](#operating)
- [Troubleshooting](#troubleshooting)

## Requirements

- Docker and systemd on the target host.
- The external proxy network (default `proxy`; in MASH, the playbook's
  `mash_playbook_reverse_proxyable_services_additional_network`) present **before
  this role runs**. The playbook's Traefik component creates it when the playbook
  manages Traefik; standalone, create it with `docker network create proxy`.
- The TURN server running with the same TURN REST secret.
- Nextcloud with the Talk app.

The role expects `com.devture.ansible.role.playbook_help` and
`com.devture.ansible.role.systemd_docker_base` (provided by the MASH playbook), the
`community.docker` collection, and the `nats` role installed from
`git+https://github.com/littlecedar/ansible-role-mash-nats.git` at `v2.15.1-0`.

## Container images

The role consumes two images built and published by this repository. The published
packages are public, so the default pulls need no registry login. If you mirror them to
private packages, authenticate the target Docker daemon with a token that has
`read:packages`.

| Service | Default image | Pinned version |
| --- | --- | --- |
| Janus | `ghcr.io/littlecedar/ansible-role-nextcloud-talk-hpb:1.4.3` | Janus `1.4.3` (`1f0b75ca`) |
| Spreed signaling | `ghcr.io/littlecedar/ansible-role-nextcloud-talk-hpb-spreed:2.1.1` | Spreed `2.1.1` (`e7a8fb7a`) |

Overrides for the signaling image:

| Variable | Default |
| --- | --- |
| `nextcloud_talk_hpb_signaling_container_image` | `ghcr.io/littlecedar/ansible-role-nextcloud-talk-hpb-spreed:{{ nextcloud_talk_hpb_signaling_container_image_tag }}` |
| `nextcloud_talk_hpb_signaling_container_image_tag` | `2.1.1` |
| `nextcloud_talk_hpb_signaling_container_image_pull` | `true` |

Overrides for Janus:

| Variable | Default |
| --- | --- |
| `nextcloud_talk_hpb_janus_container_image` | `ghcr.io/littlecedar/ansible-role-nextcloud-talk-hpb:{{ nextcloud_talk_hpb_janus_container_image_tag }}` |
| `nextcloud_talk_hpb_janus_container_image_tag` | `1.4.3` |
| `nextcloud_talk_hpb_janus_container_image_self_build` | `false` |
| `nextcloud_talk_hpb_janus_container_image_self_build_repo` | `https://github.com/littlecedar/ansible-role-nextcloud-talk-hpb.git` |
| `nextcloud_talk_hpb_janus_container_image_self_build_repo_version` | `v1.4.3-0` |

Janus has no `_container_image_pull` toggle: its image is pulled unless
`nextcloud_talk_hpb_janus_container_image_self_build` is `true`, in which case the
role clones `_self_build_repo` at `_self_build_repo_version`, builds it on the target
with `build/janus/Dockerfile`, and tags the result as `_container_image`. Only Janus
has this target-side self-build path; Spreed runs the published image, or a local image
with `nextcloud_talk_hpb_signaling_container_image_pull: false`. The NATS image is built
and published by the `ansible-role-mash-nats` repository.

To upgrade Spreed, change `ARG SPREED_VERSION`/`ARG SPREED_COMMIT` in
`build/spreed/Dockerfile`, then update
`nextcloud_talk_hpb_signaling_container_image_tag` in `defaults/main.yml` and the pin
tables in this guide and the README. The publish workflow derives its tags from the
Dockerfile ARGs; the role consumes the defaults tag. Janus upgrades are automated by
`update-janus.sh` and its weekly workflow.

The publish workflow builds both images, runs their smoke tests and the molecule
scenario, and only then pushes to GHCR. It runs on pushes to `main` and on manual
dispatch. Every run pushes `sha-<short>`; `edge`, `latest` and the service version are
pushed only when the ref is `main`, so a manual dispatch on another branch pushes just
`sha-<short>`. CI builds and smoke-tests both plus the molecule scenario on pull
requests and on manual dispatch, without pushing anything.

## Required variables

`nextcloud_talk_hpb_enabled: true` makes the role validate its configuration before
touching the host. These variables have no usable default and must be set:

| Variable | Meaning |
| --- | --- |
| `nextcloud_talk_hpb_hostname` | Public hostname of the signaling server (also the Traefik `Host()` rule) |
| `nextcloud_talk_hpb_public_ip` | Host's public IP; Janus announces it as its 1:1 NAT mapping |
| `nextcloud_talk_hpb_nextcloud_url` | Nextcloud base URL, for example `https://cloud.example.com` |
| `nextcloud_talk_hpb_signaling_secret` | Shared secret with Nextcloud Talk (same value as `occ talk:signaling:add`) |
| `nextcloud_talk_hpb_turn_static_auth_secret` | TURN REST secret; must match the TURN server's |
| `nextcloud_talk_hpb_signaling_hash_key` | Session checksum key; 32 or 64 bytes recommended (other lengths only warn) |
| `nextcloud_talk_hpb_signaling_block_key` | Session encryption key; **must be 16, 24 or 32 bytes** (validated) |
| `nextcloud_talk_hpb_signaling_internal_shared_secret_key` | Authenticates internal signaling clients |
| `nextcloud_talk_hpb_uid` / `nextcloud_talk_hpb_gid` | Owner of the rendered support files |

The bus contract is read from the `nats` role through three variables of this role, all
of which default to that role's values:

| Variable | Default |
| --- | --- |
| `nextcloud_talk_hpb_nats_token` | `{{ nats_token \| default('') }}` |
| `nextcloud_talk_hpb_nats_hostname` | `{{ nats_identifier \| default('') }}` |
| `nextcloud_talk_hpb_nats_network` | `{{ nats_container_network \| default('') }}` |

Set them explicitly to use a bus that runs outside this playbook.
`nextcloud_talk_hpb_nats_hostname` must equal `nats_identifier` when the `nats` unit
runs in the same play, because the signaling unit requires
`{{ nextcloud_talk_hpb_nats_hostname }}.service`.

Validation rejects: empty required values, an invalid `public_ip`, a
`nextcloud_url` without `http(s)://`, malformed subnets, a missing NATS container
network, an egress gateway outside the egress subnet, a malformed or inverted
`janus_rtp_port_range`, missing Traefik label values while labels are enabled, the
`allowall` backend mode without a secret, a missing external proxy network, and a
`compose.yaml` at the role root.

## Networks and subnets

| Variable | Default | Notes |
| --- | --- | --- |
| `nextcloud_talk_hpb_egress_network` | `nextcloud-talk-hpb-egress` | Bridge; signaling + host-networking Janus |
| `nextcloud_talk_hpb_egress_subnet` | `172.29.0.0/24` | Janus WebSocket ACL |
| `nextcloud_talk_hpb_egress_gateway` | `172.29.0.1` | Janus WebSocket bind address |
| `nextcloud_talk_hpb_proxy_network` | `proxy` | External; never created or deleted by this role |
| `nextcloud_talk_hpb_proxy_network_subnet` | detected | Becomes the signaling `TRUSTED_PROXIES` |

The signaling container also joins the `nats` role's internal network
(`nats_container_network`, default `nats`), where it reaches the bus at
`<nats_identifier>:4222`. That role creates and removes the network; this role only
validates that it exists.

If `egress_subnet` conflicts with something already on the host, override it together
with `egress_gateway`; validation rejects inconsistent values.

The deletion flag `nextcloud_talk_hpb_egress_network_deletion_enabled` defaults to
`true`.
`nextcloud_talk_hpb_proxy_network_deletion_enabled` exists for a possible future
migration and has no effect: the external proxy network is never removed.

## Secrets

```sh
openssl rand -hex 32   # signaling_secret, turn_static_auth_secret,
                       # signaling_internal_shared_secret_key
openssl rand -hex 16   # signaling_hash_key, signaling_block_key
```

In MASH these are derived from `mash_playbook_generic_secret_key` (see the README
snippet). The NATS token is defined by the `nats` role and lives only in that role's
`/nats/nats.conf`. This role's rendered support files live in
`nextcloud_talk_hpb_base_path` (`signaling.conf`, `janus.env`, `signaling.labels`); all
are mode `0640`. `signaling.conf` is mounted read-only, `signaling.labels` is used as
Docker's label file, and `janus.env` is passed as an environment file. The signaling
secrets stay in the mode-`0640` configuration file rather than in container environment
variables. The Janus TURN secret is in `janus.env` and is therefore visible in
`docker inspect` `Config.Env`; this role keeps all secrets out of journals, command
lines, container logs and world-readable files.

## External relay proxy (Traefik)

1. Point the role at the network your reverse proxy is attached to:
   `nextcloud_talk_hpb_proxy_network` (default `proxy`). In MASH the component sets it
   to `mash_playbook_reverse_proxyable_services_additional_network`, which is the
   playbook-managed Traefik network or the one you named for your own Traefik (see
   `components/traefik/README.md`). Standalone, create it once:
   `docker network create proxy`.
2. Either let the role render Docker labels
   (`nextcloud_talk_hpb_signaling_container_labels_traefik_enabled: true`, the default),
   or set it to `false` and route manually.

The labels route `https://<hostname>/` to `<signaling_identifier>:8081`:

```text
traefik.enable=true
traefik.docker.network=proxy
traefik.http.routers.nextcloud-talk-hpb.rule=Host(`<hostname>`)
traefik.http.routers.nextcloud-talk-hpb.entrypoints=web-secure
traefik.http.routers.nextcloud-talk-hpb.tls=true
traefik.http.routers.nextcloud-talk-hpb.tls.certResolver=default
traefik.http.services.nextcloud-talk-hpb.loadbalancer.server.port=8081
```

There is no path prefix: the signaling server owns `/spreed`, `/api/v1/welcome`,
the backend endpoints, `/proxy` and the Janus event handler. Traefik must support
WebSocket upgrade and must send `X-Real-IP` and `X-Forwarded-For`; the signaling
server trusts only `nextcloud_talk_hpb_proxy_network_subnet`.

The signaling container also publishes `127.0.0.1:8081` on the host, because the
host-networking Janus container posts its events to it. Never publish 8081 publicly.

## External TURN server (coturn)

Run coturn outside this role:

```sh
turnserver --use-auth-secret --static-auth-secret=<nextcloud_talk_hpb_turn_static_auth_secret> \
  --realm=<realm> --external-ip=<public ip> --min-port=49152 --max-port=65535
```

- Permit TURN TCP/UDP `3478` and the relay range (default `49152-65535`). That range
  must not overlap the Janus RTP range.
- Janus reaches the TURN server at `nextcloud_talk_hpb_janus_turn_server_host` /
  `..._turn_server_port` (default `127.0.0.1:3478`) and derives ephemeral TURN REST
  credentials from the shared secret.
- Nextcloud Talk supplies the public TURN/STUN URL to clients; configure it in the
  Talk admin settings (or `occ talk:turn:add` / `occ talk:stun:add`).

## Nextcloud wiring

After a deployment, register the signaling server with the Nextcloud container:

```sh
docker exec -u www-data <nextcloud_identifier> php occ talk:signaling:add \
  "https://<nextcloud_talk_hpb_hostname>" "<nextcloud_talk_hpb_signaling_secret>" --verify
docker exec -u www-data <nextcloud_identifier> php occ talk:signaling:list
```

Then add the external TURN and STUN servers in the Talk admin settings, using the
same TURN secret. The role does not modify Nextcloud.

## Firewall

| Port | Exposure |
| --- | --- |
| `443/tcp` | public (Traefik) |
| `20000-40000/udp` | public (Janus RTP/RTCP; host networking) |
| `3478/tcp+udp`, `49152-65535/udp` | public (your TURN server) |
| `8081`, `8088`, `8188` | **not** public |
| `4222` | internal `nats` network only (the bus publishes no host port) |

Janus binds its HTTP API to `127.0.0.1:8088` and its WebSocket transport to
`<egress_gateway>:8188`, with an ACL limited to the egress network. Janus matches ACL
entries as address *prefixes*, not CIDR networks, so the role derives `172.29.0.`
from `nextcloud_talk_hpb_egress_subnet`; this assumes a `/24` egress network (the
role's default). The host firewall must still drop both ports from public interfaces.
Janus runs with host networking because publishing a 20k-port UDP range through the
Docker userland proxy is not viable; if host networking is unacceptable, revisit the
topology instead of publishing the range.

## Operating

```sh
systemctl status nextcloud-talk-hpb-{signaling,janus}
journalctl -u nextcloud-talk-hpb-signaling -f
journalctl -u nextcloud-talk-hpb-janus -f
```

Both containers log through systemd (`--log-driver=none`).
Restarting one unit recreates only that container. Changing a rendered support file,
a unit file or an image sets `nextcloud_talk_hpb_restart_necessary`, which the MASH
systemd service manager uses to restart the affected units.

`nextcloud_talk_hpb_enabled: false` (plus a playbook run) stops and removes the two
units, removes the role's egress network when
`nextcloud_talk_hpb_egress_network_deletion_enabled` is true, and removes
`nextcloud_talk_hpb_base_path`. The external proxy network is untouched, and the NATS
unit and its network are removed by the `nats` role.

### Upgrading from 1.4.x

Earlier releases deployed NATS themselves. To move an existing node onto the `nats`
role:

1. Stop and disable the old unit, remove it, and reload systemd:

   ```sh
   systemctl disable --now nextcloud-talk-hpb-nats.service
   rm /etc/systemd/system/nextcloud-talk-hpb-nats.service
   systemctl daemon-reload
   ```

2. Remove the old rendered configuration:

   ```sh
   rm /nextcloud-talk-hpb/nats.conf
   ```

3. Deploy the `nats` role with `nats_token` set to the previous
   `nextcloud_talk_hpb_nats_token` value, so the existing token keeps working.
4. Run this role. The signaling server now connects to
   `nats://<nats_identifier>:4222` on the `nats` role's network.
5. Remove the old internal network, which nothing uses any more:

   ```sh
   docker network rm nextcloud-talk-hpb-hpb
   ```

## Troubleshooting

**An image cannot be pulled from GHCR.** The tag is not published yet, or the package is
not visible to the host. The published packages are public, so default pulls need no
login. If you use private mirrors, authenticate the target Docker daemon with a token
that has `read:packages`:

```sh
echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
```

This repository publishes the Janus and Spreed images; the NATS image comes from the
`ansible-role-mash-nats` repository. Alternatively, publish the tag by running the
publish workflow on `main`, or build the image locally
(`docker build -t <image> build/<service>`) and set
`nextcloud_talk_hpb_signaling_container_image` with
`nextcloud_talk_hpb_signaling_container_image_pull: false`. Janus has no pull toggle
and is always pulled from `nextcloud_talk_hpb_janus_container_image`
unless self-build is enabled, so a locally tagged image alone is not enough: set
`nextcloud_talk_hpb_janus_container_image_self_build: true` to build it from source on
the target, or point `nextcloud_talk_hpb_janus_container_image` at a registry image the
host can pull.

**The signaling server logs `Processing Janus events` never appear.** Janus must be
able to reach `ws://127.0.0.1:8081/spreed`: check that the signaling container
publishes `127.0.0.1:8081` and that Janus runs with host networking.
`journalctl -u nextcloud-talk-hpb-janus` shows the event handler connection errors.

**Janus starts but calls have no media.** Check the RTP range is reachable from
outside, `nextcloud_talk_hpb_public_ip` matches the host's real public address, and
the host firewall does not block `20000-40000/udp`.

**Nextcloud reports the signaling server as unreachable.** Verify the shared secret
matches on both sides (`occ talk:signaling:list`), that `nextcloud_talk_hpb_nextcloud_url`
is exactly the Nextcloud base URL, and that the signaling server can reach Nextcloud.

**`Could not create janus MCU: data channels are not supported`.** The signaling
server requires a Janus build with data channels. A third-party Janus image built with
`--disable-data-channels` connects and reports its version, then gets rejected. Use
this repository's image (data channels and `usrsctp` are enabled) or rebuild Janus
accordingly.

**TURN never succeeds.** Janus and Nextcloud must use the same TURN REST secret, and
the TURN server must be configured for TURN REST credentials (`--use-auth-secret`).
A static-credential TURN server does not work with the generated credentials.

**`a changed-users warning`** in the signaling log is normal after session resumption
and is non-blocking once calls work.

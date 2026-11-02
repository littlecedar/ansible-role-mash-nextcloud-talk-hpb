<!--
SPDX-FileCopyrightText: 2026 Travis Wichert

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Janus configuration overrides

The image entrypoint reads overrides from `JANUS_OVERRIDE_DIR` (default `/etc/janus.d`) on
every container start and applies them before its own HPB patches. The directory is consumed
only when it is mounted read-only at that same path — `/etc/janus.d` unless the environment
variable is changed.

This `conf.d/` directory is the repository's example/working directory: the role does **not**
deploy it to the target host, and nothing in it reaches the container on its own. Copy the
`.jcfg` files you want to a host directory you control, for example `/srv/janus-overrides`,
and mount that directory.

The role has no built-in mount hook for overrides, and the Janus unit is Ansible-managed, so
editing the generated unit in place is not durable — the next role run overwrites it. To
persist a mount, either add it to `templates/systemd/janus.service.j2` in the role, or use a
systemd drop-in. The mount belongs to the `docker create` line, but resetting `ExecStartPre=`
clears every `ExecStartPre=` entry from the generated unit, so the drop-in must repeat all of
them in their original order: the container cleanup command, the `docker create` command
(including the network and hardening flags) with the extra
`--volume=/srv/janus-overrides:/etc/janus.d:ro`, and any `docker network connect` commands.
Run `systemctl daemon-reload` and then `systemctl restart nextcloud-talk-hpb-janus`.
`scripts/smoke-test-janus.sh` mounts a temporary override directory directly instead.

## Semantics

- Only files ending in `.jcfg` are considered; everything else is ignored.
- Each file **replaces** the whole stock config of the same name. The entrypoint does not
  merge, append or patch individual keys. A file whose name matches no stock config is
  copied anyway and a warning is printed:

  ```text
  janus-entrypoint: WARNING 'foo.jcfg' matches no stock config
  ```

- The overlay is applied **before** the entrypoint's own HPB patches. Those patches win for
  the fields listed below, so overriding them here has no effect:
  - `janus.transport.http.jcfg`: `http`, `https`, `port`, `ip`, `acl`, `admin_http`
  - `janus.transport.websockets.jcfg`: `ws`, `wss`, `ws_port`, `ws_ip`, `ws_acl`, `admin_ws`
  - `janus.jcfg`: `broadcast` (when `JANUS_EVENT_BACKEND` is set) and the whole `nat:` block
    (when `JANUS_TURN_SERVER` is set)
  - `janus.eventhandler.wsevh.jcfg`: `enabled`, `backend`, `subprotocol`, `events`,
    `events_cap_on_reconnect`, `events_max_queue` (when `JANUS_EVENT_BACKEND` is set)
  - `janus.plugin.videoroom.jcfg`: the sample `room-1234` block is always removed

- Configs are rendered into `/tmp/janus-config` with `umask 077` because they contain TURN
  credentials, and `/tmp` is a tmpfs. Nothing in this directory is modified.

## Extracting the stock configs

```sh
docker run --rm --entrypoint cat \
  ghcr.io/littlecedar/ansible-role-mash-nextcloud-talk-hpb:1.4.3 \
  /opt/janus/etc/janus/janus.jcfg > conf.d/janus.jcfg
```

For a locally built image, substitute `ansible-role-mash-nextcloud-talk-hpb:local`.

Available configs: `janus.jcfg`, `janus.transport.http.jcfg`,
`janus.transport.websockets.jcfg`, `janus.eventhandler.wsevh.jcfg`,
`janus.plugin.videoroom.jcfg`, plus the configs of the features that are disabled in this
image (they have no effect).

## Restart

Overrides are read at container start only, and the unit recreates the container through
`ExecStartPre`, so restart the unit rather than the container:

```sh
systemctl restart nextcloud-talk-hpb-janus
```

Substitute the actual identifier if `nextcloud_talk_hpb_identifier` is customized; the unit
is named after it.

## Security warning

The defaults exist for a reason: the HTTP and WebSocket APIs are loopback-only with
loopback ACLs, both admin transports are disabled, and no sample rooms exist. An override
that re-enables an admin transport or widens `ws_acl` exposes an **unauthenticated** API
(the Janus API has no authentication layer) to whatever can reach the port. The stock
`admin_secret` is a well-known placeholder; change it before enabling any admin transport.

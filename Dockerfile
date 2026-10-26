# syntax=docker/dockerfile:1
# Build from the parent directory:
#   docker build -t penta-ai-worker-base-image:0.2.0 ./penta-ai-worker-base-image
#
# Gateway/worker connection contract:
#   SSH_PUBLIC_KEY: required OpenSSH public key (multiple keys: one per line).
#   The matching PRIVATE key stays in penta-ai-gateway; never send it to a worker.
#   SSH: coder@<worker-container-name>:22; project files: /workspace.
#   Web IDE: http://<worker-container-name>:8080 (proxy HTTP and WebSockets).
#
# Example on a user-defined Docker network (no host ports are published):
#   docker network create penta-ai
#   docker network connect penta-ai penta-ai-gateway
#   export SSH_PUBLIC_KEY="$(cat /trusted/path/gateway_ed25519.pub)"
#   docker run -d --name worker-001 --network penta-ai \
#     -e SSH_PUBLIC_KEY -e PASSWORD \
#     --mount source=worker-001-project,target=/workspace \
#     --mount source=worker-001-host-keys,target=/var/lib/penta/ssh \
#     penta-ai-worker-base-image:0.2.0
#   Inside the gateway, using its private key and a provisioned known_hosts file:
#     ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
#       -i /run/secrets/worker_key coder@worker-001 'cd /workspace && git status'
#   Pin the worker host public key via the trusted container management plane:
#     docker exec worker-001 cat /var/lib/penta/ssh/ssh_host_ed25519_key.pub
#   Keep host keys per worker identity; never share them between workers.
#
# PASSWORD/HASHED_PASSWORD is the optional code-server credential, separate from SSH.
# Without it, code-server generates a password in the runtime user's config file.
# Behind the gateway's authentication, use IMAGE --auth none /workspace and prevent
# direct client access to the worker. EXPOSE is metadata; network membership is set
# by the gateway/orchestrator, not by this Dockerfile. Use a per-project network
# and --internal if runtime egress must also be blocked.
#
# Example downstream Dockerfile:
#   FROM penta-ai-worker-base-image:0.2.0
#   USER root
#   RUN apt-get update \
#       && apt-get install -y --no-install-recommends python3 python3-venv \
#       && rm -rf /var/lib/apt/lists/*
#   LABEL io.penta.ai.description="Python development workspace" \
#         io.penta.ai.tools='["bash","git","git-lfs","curl","ssh","jq","rg","python3"]'
#   USER root
#   WORKDIR /workspace
# Keep USER root and the inherited ENTRYPOINT: sshd needs root to create sessions,
# while the launcher runs code-server as coder and sshd logs users in as coder.
# CMD overrides are code-server arguments, not application startup commands.
# Persist /home/coder for editor state; bind mounts must allow UID/GID 1000:1000.
# No anonymous volumes are created. Snapshot /workspace before deleting a worker.

# Official code-server image: Debian 13, linux/amd64 and linux/arm64.
# Use an internal registry/digest override when required. Build with registry/APT
# mirror access, then transfer the built image for air-gapped runtime.
ARG CODE_SERVER_IMAGE=codercom/code-server:4.143.1
FROM ${CODE_SERVER_IMAGE}

USER root

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        git-lfs \
        jq \
        openssh-client \
        openssh-server \
        ripgrep \
        util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_* /etc/sudoers.d/nopasswd \
    && chmod 0755 /usr/local/bin/fixuid \
    && usermod --shell /bin/bash coder \
    && install -d -o coder -g coder -m 0755 \
        /workspace /home/coder/.config /home/coder/.local/share/code-server

# A dedicated config avoids inheriting distro drop-ins or password login defaults.
COPY <<'EOF' /etc/ssh/penta_sshd_config
Port 22
HostKey /var/lib/penta/ssh/ssh_host_ed25519_key
PidFile /run/sshd.pid
PermitRootLogin no
AllowUsers coder
PubkeyAuthentication yes
AuthenticationMethods publickey
AuthorizedKeysFile /run/penta/authorized_keys/%u
StrictModes yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM yes
PermitUserEnvironment no
DisableForwarding yes
X11Forwarding no
PrintMotd no
LoginGraceTime 30
MaxAuthTries 3
ClientAliveInterval 60
ClientAliveCountMax 3
Subsystem sftp internal-sftp
EOF

# Embedded scripts keep the repository limited to this Dockerfile.
COPY --chmod=0755 <<'EOF' /usr/local/bin/penta-worker-entrypoint
#!/bin/bash
set -euo pipefail

fail() { printf 'penta-worker: %s\n' "$1" >&2; exit 1; }

[[ "$(id -u)" == 0 ]] || fail 'Start the container as root; services drop to coder for development.'
[[ -n "${SSH_PUBLIC_KEY:-}" ]] || fail 'SSH_PUBLIC_KEY is required; provide a public key, never a private key.'

install -d -m 0755 /run/sshd /run/penta /run/penta/authorized_keys
install -d -m 0700 /var/lib/penta/ssh

# Validate each complete key before either service starts. Replace the authorized
# keys on every start so persisted homes cannot retain stale gateway credentials.
key_file=$(mktemp /run/penta/authorized_keys/.coder.XXXXXX)
key_count=0
while IFS= read -r key || [[ -n "$key" ]]; do
    key="${key%$'\r'}"
    [[ "$key" =~ ^[[:space:]]*$ || "$key" == \#* ]] && continue
    case "$key" in
        ssh-*|ecdsa-*|sk-*) ;;
        *) rm -f "$key_file"; fail 'SSH_PUBLIC_KEY must contain OpenSSH public key lines.' ;;
    esac
    if ! printf '%s\n' "$key" | ssh-keygen -lf /dev/stdin >/dev/null 2>&1; then
        rm -f "$key_file"
        fail 'SSH_PUBLIC_KEY contains an invalid public key.'
    fi
    printf '%s\n' "$key" >> "$key_file"
    key_count=$((key_count + 1))
done <<< "$SSH_PUBLIC_KEY"
[[ "$key_count" -gt 0 ]] || { rm -f "$key_file"; fail 'SSH_PUBLIC_KEY contains no public keys.'; }
chmod 0644 "$key_file"
mv -f "$key_file" /run/penta/authorized_keys/coder
unset SSH_PUBLIC_KEY key

# Host private keys are generated at runtime, never baked into the base image.
if [[ ! -f /var/lib/penta/ssh/ssh_host_ed25519_key ]]; then
    ssh-keygen -q -t ed25519 -N '' -f /var/lib/penta/ssh/ssh_host_ed25519_key
fi
chmod 0600 /var/lib/penta/ssh/ssh_host_ed25519_key
ssh-keygen -y -f /var/lib/penta/ssh/ssh_host_ed25519_key \
    > /var/lib/penta/ssh/ssh_host_ed25519_key.pub
chmod 0644 /var/lib/penta/ssh/ssh_host_ed25519_key.pub
/usr/sbin/sshd -t -f /etc/ssh/penta_sshd_config

sshd_pid=''
ide_pid=''
cleanup() {
    trap - EXIT TERM INT
    [[ -z "$sshd_pid" ]] || kill -TERM "$sshd_pid" 2>/dev/null || true
    [[ -z "$ide_pid" ]] || kill -TERM "$ide_pid" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# SSH must not receive the browser IDE credentials in its environment.
env -u PASSWORD -u HASHED_PASSWORD /usr/sbin/sshd -D -e -f /etc/ssh/penta_sshd_config &
sshd_pid=$!
if [[ "$#" == 0 ]]; then set -- /workspace; fi
runuser -u coder -- /usr/bin/code-server \
    --bind-addr 0.0.0.0:8080 --disable-telemetry --disable-update-check "$@" &
ide_pid=$!

# If either required service stops, stop the other and let the orchestrator restart
# or replace this container. Do not leave a partially working workspace running.
status=0
wait -n "$sshd_pid" "$ide_pid" || status=$?
printf 'penta-worker: a required service stopped; shutting down.\n' >&2
if [[ "$status" == 0 ]]; then status=1; fi
exit "$status"
EOF

COPY --chmod=0755 <<'EOF' /usr/local/bin/penta-worker-healthcheck
#!/bin/bash
set -euo pipefail
curl --fail --silent --show-error --max-time 3 http://127.0.0.1:8080/healthz >/dev/null
test -s /run/sshd.pid
kill -0 "$(cat /run/sshd.pid)"
EOF

# Labels are descriptive metadata for the agent, not authorization rules.
# Derived images should update description/tools and can add project commands.
LABEL org.opencontainers.image.title="Penta AI Worker Base Image" \
      org.opencontainers.image.description="Extensible worker with code-server and key-only SSH access" \
      org.opencontainers.image.version="0.2.0" \
      io.penta.workspace.schema-version="1" \
      io.penta.workspace.directory="/workspace" \
      io.penta.workspace.user="coder" \
      io.penta.workspace.uid="1000" \
      io.penta.workspace.gid="1000" \
      io.penta.workspace.ide="code-server" \
      io.penta.workspace.ide.port="8080" \
      io.penta.workspace.ssh.port="22" \
      io.penta.workspace.ssh.public-key-env="SSH_PUBLIC_KEY" \
      io.penta.workspace.ssh.host-public-key="/var/lib/penta/ssh/ssh_host_ed25519_key.pub" \
      io.penta.ai.description="Debian worker with a browser IDE and gateway SSH access as coder. Both use /workspace. Add project runtimes in a derived image." \
      io.penta.ai.tools='["bash","git","git-lfs","curl","ssh","jq","rg"]'

ENV HOME=/home/coder \
    USER=coder \
    SHELL=/bin/bash

WORKDIR /workspace
# Root is only required for service management; IDE and SSH sessions use coder.
USER root
EXPOSE 22 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["/usr/local/bin/penta-worker-healthcheck"]

# dumb-init forwards termination signals and reaps orphaned service children.
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/usr/local/bin/penta-worker-entrypoint"]
CMD ["/workspace"]

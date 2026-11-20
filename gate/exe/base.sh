#!/bin/bash
# What a bare `ubuntu:26.04` exe.dev VM lacks that a Fly Sprite's base image
# supplied (rig's EXE.md, step 1). Runs as root on the golden VM before
# gate/image/provision.sh, which then runs as `gate`; provision.sh stays as
# it is, since its hash is the Sprite pool's stamp.
#
#   ssh <vm>.exe.xyz 'bash -s' < gate/exe/base.sh
#
# exe's SSH logs every user in as the image's default user (root here), and
# Postgres will not run as root, so parts run as `gate`, which has
# passwordless sudo as the Sprite's user did. Python 3.13 goes first on a
# login shell's PATH: heaters' `uv run` scripts failed on Ubuntu's 3.14
# (no pydantic-core wheels). exe-init is PID 1 (no systemd), so what each
# boot needs (`boot`, below) is the runner's to call on every fresh copy.
#
# Idempotent; `bash base.sh boot` does only the per-boot step.
set -euo pipefail
PY=3.13 UV=0.8.8

boot() {
  # A bare image lacks these, and bash's process substitution needs them.
  local f
  for f in fd:/proc/self/fd stdin:/proc/self/fd/0 stdout:/proc/self/fd/1 stderr:/proc/self/fd/2; do
    [ -e "/dev/${f%%:*}" ] || ln -s "${f#*:}" "/dev/${f%%:*}"
  done
}
boot
[ "${1:-}" = boot ] && exit 0

export DEBIAN_FRONTEND=noninteractive
need=(sudo curl ca-certificates git xz-utils zstd locales procps less)
if ! dpkg -s "${need[@]}" >/dev/null 2>&1; then
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends "${need[@]}" >/tmp/base-apt.log
fi

id gate >/dev/null 2>&1 || useradd --create-home --shell /bin/bash gate
echo 'gate ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/gate
chmod 440 /etc/sudoers.d/gate

if ! /usr/local/bin/uv --version 2>/dev/null | grep -q "^uv $UV "; then
  curl -fsSL "https://github.com/astral-sh/uv/releases/download/$UV/uv-x86_64-unknown-linux-gnu.tar.gz" |
    tar -xz -C /usr/local/bin --strip-components=1 uv-x86_64-unknown-linux-gnu/uv
fi
export UV_PYTHON_INSTALL_DIR=/opt/gate/python
install -d -m 755 /opt/gate
/usr/local/bin/uv python install -q "$PY"
py=$(/usr/local/bin/uv python find "$PY")
cat >/etc/profile.d/gate.sh <<ENV
# rig's gate/exe/base.sh: Python $PY first, for uv and for scripts.
export PATH=${py%/*}:\$PATH UV_PYTHON=$PY UV_PYTHON_INSTALL_DIR=/opt/gate/python
ENV
echo "base: $(${py} --version), uv $UV, user gate"

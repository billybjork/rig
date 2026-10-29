#!/bin/bash
# The one gate image (rig's gate/README.md, "The image"): builds a Fly Sprite
# (Ubuntu 26.04 "resolute", user sprite, passwordless sudo) that gates every
# project in ~/dev. A project whose `.gate.json` names `image` gets it: its
# part's job (sprite/job.sh) runs it, staged with the part, as
#
#   bash image.sh <stamp> <name> <pin files...>
#
# whenever the Sprite's ~/<name>-stamp is not the commit's. The pin files are
# the project's, from its checkout: an asdf `.tool-versions` (erlang, elixir,
# nodejs) and any KEY=VALUE files (NPM_VERSION). Each project's toolchain goes
# beside the others' under /opt/gate (erlang-<v>, elixir-<v>-otp-<major>,
# node-<v>), and ~/<name>-env.sh puts that project's on PATH, so two projects
# pinning different versions share a Sprite and a bump installs beside what
# runs, the old versions staying for branches that still pin them. What every
# project uses (apt's packages, Postgres 17 with pgvector and pg_jsonschema,
# Swift, just, uv) is pinned here.
#
# Idempotent: each step checks what is installed and skips when it matches,
# so rerunning it on a built Sprite takes seconds. The stamp goes to
# ~/<name>-stamp only when every step succeeded. The Sprite gets no secret.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
usage="usage: image.sh <stamp> <name> <tool-versions> [KEY=VALUE files...]"
stamp=${1:?$usage} name=${2:?$usage} versions=${3:?$usage}
shift 3
tool() { awk -v t="$1" '$1 == t {print $2}' "$versions"; }
OTP=$(tool erlang) NODE=$(tool nodejs) ELIXIR=$(tool elixir)
ELIXIR=${ELIXIR%%-otp-*}
NPM=$(for f in "$@"; do sed -n 's/^NPM_VERSION=//p' "$f"; done | tail -1)
PG=17 SWIFT=6.4.0 PG_JSONSCHEMA=0.3.4 JUST=1.43.0 UV=0.8.8
opt=/opt/gate
erlang=$opt/erlang-$OTP elixir=$opt/elixir-$ELIXIR-otp-${OTP%%.*} node=$opt/node-$NODE
t0=$(date +%s)
step() { echo "provision: $(($(date +%s) - t0))s $*"; }
skip() { echo "provision:   already there"; }
rm -f ~/"$name-stamp"
cd /tmp
sudo install -d -o "$(id -u)" -g "$(id -g)" "$opt"

step apt
# The union of the projects' needs. soco: libvips, the HEIC plugins and an
# HEVC encoder (its media tests), python3 (mix modal.check). heaters:
# pgvector, libz3/binutils/libstdc++ and libedit (Swift). Every project:
# ffmpeg, build-essential, inotify-tools, and gdb for the stack of a core a
# part leaves (sprite/job.sh keeps them).
packages=(ffmpeg libvips-tools libheif-plugin-libde265 libheif-plugin-x265 "postgresql-$PG"
  "postgresql-$PG-pgvector" build-essential unzip inotify-tools libncurses6 libedit2 bc git
  python3 gdb jq libz3-dev binutils libstdc++-14-dev)
if dpkg -s "${packages[@]}" >/dev/null 2>&1; then skip; else
  sudo install -d /usr/share/postgresql-common/pgdg
  sudo curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt resolute-pgdg main" |
    sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
  sudo apt-get update -qq >/dev/null
  sudo -E apt-get install -y -qq --no-install-recommends "${packages[@]}" >/tmp/apt.log
  # The packaged cluster is not used: each project's setup runs its own.
  sudo pg_dropcluster "$PG" main --stop >/dev/null 2>&1 || true
fi

step "pg_jsonschema $PG_JSONSCHEMA"
if grep -qs "default_version = '$PG_JSONSCHEMA'" "/usr/share/postgresql/$PG/extension/pg_jsonschema.control"; then skip; else
  curl -fsSL -o pg_jsonschema.deb "https://github.com/supabase/pg_jsonschema/releases/download/v$PG_JSONSCHEMA/pg_jsonschema-v$PG_JSONSCHEMA-pg$PG-amd64-linux-gnu.deb"
  sudo dpkg -i pg_jsonschema.deb >/dev/null
  rm -f pg_jsonschema.deb
fi

step "just $JUST, uv $UV"
if [ "$(just --version 2>/dev/null)" = "just $JUST" ]; then skip; else
  curl -fsSL "https://github.com/casey/just/releases/download/$JUST/just-$JUST-x86_64-unknown-linux-musl.tar.gz" | sudo tar -xz -C /usr/local/bin just
fi
if /usr/local/bin/uv --version 2>/dev/null | grep -q "^uv $UV "; then skip; else
  curl -fsSL "https://github.com/astral-sh/uv/releases/download/$UV/uv-x86_64-unknown-linux-gnu.tar.gz" |
    sudo tar -xz -C /usr/local/bin --strip-components=1 uv-x86_64-unknown-linux-gnu/uv
fi

step "swift $SWIFT"
# swift.org's Ubuntu 26.04 build (the 24.04 one needs libxml2.so.2 and ICU 74).
if [ -x "$opt/swift-$SWIFT/usr/bin/swift" ]; then skip; else
  curl -fsSL -o swift.tgz "https://download.swift.org/swift-$SWIFT-release/ubuntu2604/swift-$SWIFT-RELEASE/swift-$SWIFT-RELEASE-ubuntu26.04.tar.gz"
  rm -rf "$opt/swift-$SWIFT.tmp" && mkdir -p "$opt/swift-$SWIFT.tmp"
  tar -xzf swift.tgz -C "$opt/swift-$SWIFT.tmp" --strip-components=1
  mv "$opt/swift-$SWIFT.tmp" "$opt/swift-$SWIFT"
  rm -f swift.tgz
fi

# Each toolchain unpacks beside its final path and moves there whole, so a
# Sprite that dies mid-install leaves no half a version that looks done.
step "otp $OTP"
if [ "$(cat "$erlang/releases/${OTP%%.*}/OTP_VERSION" 2>/dev/null)" = "$OTP" ]; then skip; else
  curl -fsSL -o otp.tar.gz "https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-$OTP.tar.gz"
  rm -rf "$erlang" && mkdir -p "$erlang"
  tar -xzf otp.tar.gz -C "$erlang" --strip-components=1
  # Install writes the final path into the scripts it rewrites, so it runs
  # in place; OTP_VERSION, the check above, is read only after it.
  mv "$erlang/releases/${OTP%%.*}/OTP_VERSION" "$erlang/OTP_VERSION.pending"
  (cd "$erlang" && ./Install -minimal "$erlang" >/dev/null)
  mv "$erlang/OTP_VERSION.pending" "$erlang/releases/${OTP%%.*}/OTP_VERSION"
  rm -f otp.tar.gz
fi

step "elixir $ELIXIR"
if [ "$(cat "$elixir/VERSION" 2>/dev/null)" = "$ELIXIR" ]; then skip; else
  curl -fsSL -o elixir.zip "https://builds.hex.pm/builds/elixir/v$ELIXIR-otp-${OTP%%.*}.zip"
  rm -rf "$elixir" "$elixir.tmp" && mkdir -p "$elixir.tmp" && unzip -qo elixir.zip -d "$elixir.tmp"
  mv "$elixir.tmp" "$elixir"
  rm -f elixir.zip
fi

step "node $NODE"
if [ "$("$node/bin/node" -v 2>/dev/null)" = "v$NODE" ]; then skip; else
  rm -rf "$node" "$node.tmp" && mkdir -p "$node.tmp"
  curl -fsSL "https://nodejs.org/dist/v$NODE/node-v$NODE-linux-x64.tar.xz" | tar -xJ -C "$node.tmp" --strip-components=1
  mv "$node.tmp" "$node"
fi
# A pinned npm goes under the project's own prefix, so two projects on one
# Node can pin different ones; Mix's archives (hex, rebar) are each
# project's own too (MIX_HOME), built for its Elixir.
npm_prefix=~/.gate-npm/$name
if [ -z "$NPM" ]; then
  rm -rf "$npm_prefix"
elif [ "$(PATH="$npm_prefix/bin:$node/bin:$PATH" npm -v 2>/dev/null)" = "$NPM" ]; then
  step "npm $NPM"
  skip
else
  step "npm $NPM"
  PATH="$node/bin:$PATH" npm install --global --silent --prefix "$npm_prefix" "npm@$NPM"
fi

step "env ~/$name-env.sh"
cat >~/"$name-env.sh" <<ENV
# $name's toolchain on this gate Sprite (rig's gate/image/provision.sh).
export PATH=$npm_prefix/bin:$erlang/bin:$elixir/bin:$node/bin:$opt/swift-$SWIFT/usr/bin:/usr/local/bin:\$PATH
export LANG=C.UTF-8 LC_ALL=C.UTF-8 MIX_HOME=\$HOME/.gate-mix/$name HEX_HOME=\$HOME/.hex
ENV
. ~/"$name-env.sh"
mix local.hex --force --if-missing >/dev/null
mix local.rebar --force --if-missing >/dev/null

step versions
elixir -v | tail -1
echo "node $(node -v), npm $(npm -v)"
swift --version 2>&1 | head -1
ffmpeg -version | head -1
vips --version
"/usr/lib/postgresql/$PG/bin/postgres" --version
python3 --version
echo "$stamp" >~/"$name-stamp"
step "done, stamp $stamp"

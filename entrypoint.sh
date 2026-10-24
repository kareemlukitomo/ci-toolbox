#!/bin/sh
# ci-toolbox entrypoint.
#
#   no argument or "-"        copy the toolbox to $CI_TOOLS_TARGET (default /ci-tools)
#   a path that is not a file copy the toolbox to that path
#   anything else             run it as a command, for example: trivy --version
set -eu

if [ "$#" -eq 0 ] || [ "$1" = "-" ]; then
  target="${CI_TOOLS_TARGET:-/ci-tools}"
elif [ "${1#/}" != "$1" ] && [ ! -f "$1" ]; then
  target="$1"
else
  exec "$@"
fi

case "$target" in
  /opt/ci-tools|/opt/ci-tools/)
    echo "ci-toolbox: target must differ from /opt/ci-tools" >&2
    exit 64
    ;;
esac

if ! mkdir -p "$target/bin" 2>/dev/null; then
  echo "ci-toolbox: cannot create ${target}/bin" >&2
  echo "ci-toolbox: the volume must be writable by uid ${CI_TOOLS_UID:-65532}." >&2
  echo "ci-toolbox: a Kubernetes emptyDir is mode 0777 and works. A host bind mount needs" >&2
  echo "ci-toolbox: chmod 0777 on the host directory, or fsGroup, or a root initContainer." >&2
  exit 73
fi

cp -R /opt/ci-tools/bin/. "$target/bin/" || {
  echo "ci-toolbox: cannot copy binaries into ${target}/bin" >&2
  exit 74
}
cp /opt/ci-tools/versions.env "$target/versions.env"
cp /opt/ci-tools/MANIFEST "$target/MANIFEST"
chmod -R a+rX "$target/bin"
chmod a+r "$target/versions.env" "$target/MANIFEST"

echo "ci-toolbox: copied to ${target}/bin" >&2
cat "$target/MANIFEST"

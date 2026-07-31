#!/usr/bin/env bash
set -euo pipefail

# Environment variables
BUILD_DIR="/tmp/pg_deb_build"
SRC_DIR="${BUILD_DIR}/pgedge-vectorizer-${PGEDGE_VECTORIZER_VERSION}"

export DEBIAN_FRONTEND=noninteractive

prepare() {

  setup_apt_build_env

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys

  rm -rf "$SRC_DIR"
  mkdir -p "$BUILD_DIR"

  stage_source "${BUILD_DIR}/${SRC_TARBALL}"
  tar -C "$BUILD_DIR" -xzf "${BUILD_DIR}/${SRC_TARBALL}"

  echo "Moving Debian packaging into source directory..."
  cp -rp "${COMPONENT_DIR}/deb/debian" "$SRC_DIR/"
  cp "$SRC_DIR/debian/control.in" "$SRC_DIR/debian/control"
  sed -i "s|PG_MAJOR_VERSION|${PG_MAJOR_VERSION}|g" "$SRC_DIR/debian/control"
  mv "$SRC_DIR/debian/pgedge-postgresql-vectorizer.install" "$SRC_DIR/debian/pgedge-postgresql-${PG_MAJOR_VERSION}-vectorizer.install"
  sed -i "s|PG_MAJOR_VERSION|${PG_MAJOR_VERSION}|g" "$SRC_DIR/debian/pgedge-postgresql-${PG_MAJOR_VERSION}-vectorizer.install"

  echo "Installing build dependencies..."
  cd "$SRC_DIR"
  sudo apt-get update
  sudo apt-get build-dep -y .
}

build() {

  cd "$SRC_DIR"
  echo "Building Debian package..."
  DISTRO=$(lsb_release -cs)
  # PGEDGE_VECTORIZER_DEB_VERSION carries the '~<pretag>' form for pre-releases
  # so they sort below stable; it equals PGEDGE_VECTORIZER_VERSION for a GA build.
  rm -rf debian/changelog
  echo "pgedge-vectorizer (${PGEDGE_VECTORIZER_DEB_VERSION}-${PGEDGE_VECTORIZER_BUILDNUM}.${DISTRO}) unstable; urgency=low" >> debian/changelog
  echo "  * Update Release." >> debian/changelog
  echo " -- pgEdge Build Team <support@pgedge.com>  $(date -R)" >> debian/changelog
  dch -D "$DISTRO" --force-distribution -v "${PGEDGE_VECTORIZER_DEB_VERSION}-${PGEDGE_VECTORIZER_BUILDNUM}.${DISTRO}" "pgEdge pgedge-vectorizer $PGEDGE_VECTORIZER_DEB_VERSION for $DISTRO"

  PATH=/usr/lib/postgresql/${PG_MAJOR_VERSION}/bin:$PATH dpkg-buildpackage -us -uc -b
}

post_build() {
  echo "Copying .deb packages to output..."
  sudo mkdir -p "/output"
  # Rename .ddeb files to .deb files
  rename_ddeb_packages $BUILD_DIR
  sudo cp "$BUILD_DIR"/*.deb "/output" || echo "No .deb packages found."
}

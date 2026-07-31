#!/bin/bash
set -euo pipefail

RHEL="$(rpm --eval %rhel)"

prepare() {
  setup_dnf_build_env
  echo "Copying packaging files..."
  cp "${COMPONENT_DIR}/rpm/pgedge_vectorizer.spec" ~/rpmbuild/SPECS/

  # The spec's Source0 basename is v<version>.tar.gz, while %setup expects the
  # pgedge-vectorizer-<version>/ directory inside it — which is what
  # release.yml's `git archive --prefix` produces.
  stage_source ~/rpmbuild/SOURCES/v${PGEDGE_VECTORIZER_VERSION}.tar.gz

  # Parallel make is not safe for this extension.
  sed -i 's|%{?_smp_mflags}||g' ~/rpmbuild/SPECS/pgedge_vectorizer.spec

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys

  echo "🔧 Installing RPM build dependencies..."
  dnf builddep -y \
    --define "pgmajorversion ${PG_MAJOR_VERSION}" \
    --define "pginstdir /usr/pgsql-${PG_MAJOR_VERSION}" \
    --define "pgedge_vectorizer_version ${PGEDGE_VECTORIZER_VERSION}" \
    --define "pgedge_vectorizer_buildnum ${PGEDGE_VECTORIZER_BUILDNUM}" \
    ~/rpmbuild/SPECS/pgedge_vectorizer.spec
}

build() {
  echo "Building RPM and SRPM..."
  QA_RPATHS=$(( 0xffff )) rpmbuild -ba ~/rpmbuild/SPECS/pgedge_vectorizer.spec \
    --define "pgmajorversion ${PG_MAJOR_VERSION}" \
    --define "pginstdir /usr/pgsql-${PG_MAJOR_VERSION}" \
    --define "pgedge_vectorizer_version ${PGEDGE_VECTORIZER_VERSION}" \
    --define "pgedge_vectorizer_buildnum ${PGEDGE_VECTORIZER_BUILDNUM}"
}

post_build() {
  echo "📤 Copying built RPMs to /output..."
  mkdir -p /output
  cp -v ~/rpmbuild/RPMS/*/*.rpm /output/ || echo "No binary RPMs found"
  cp -v ~/rpmbuild/SRPMS/*.src.rpm /output/ || echo "No SRPM found"

  sign_rpms /output/*.rpm
  validate_signatures /output/*.rpm
}

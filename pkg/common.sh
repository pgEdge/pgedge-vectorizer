#!/usr/bin/env bash
# common.sh - packaging environment for pgedge-vectorizer.
#
# pgedge-vectorizer is a PostgreSQL extension: one build per PG major.
# pgedge-detect-build-matrix reads this to fan the matrix out over pg_versions.
PER_PG_VERSION=true

export PG_VERSION="${PG_VERSION:-17}"
export PG_MAJOR_VERSION="$(echo "$PG_VERSION" | cut -d. -f1)"

export PG_PGEDGE_VECTORIZER_REPO="https://github.com/pgEdge/pgedge-vectorizer.git"
export PGEDGE_VECTORIZER_BRANCH="${COMPONENT_BRANCH:-v1.1}"

# Upstream version, suffix-stripped (e.g. 1.1). Names the source tarball's
# internal directory (pgedge-vectorizer-<version>/, which the spec's
# `%setup -n %{sname}-%{version}` expects) and the RPM Version.
export PGEDGE_VECTORIZER_VERSION="${COMPONENT_VERSION:-1.1}"
export PGEDGE_VECTORIZER_BUILDNUM=${COMPONENT_BUILDNUM:-1}

export REPO_TYPE="${REPO_TYPE:-daily}"

# DEB only: move a pre-release pretag (COMPONENT_BUILDNUM='beta3_1') into the
# upstream version with a leading '~' so pre-releases sort BELOW stable in
# dpkg/reprepro: 1.1~beta3-1.noble < 1.1-1.noble.
#
# The '~' form goes in a SEPARATE variable used only by the debian/changelog:
# PGEDGE_VECTORIZER_VERSION itself must stay clean because it names the source
# tarball and its unpack directory (a '~' there would break %setup and the DEB
# extract).
export PGEDGE_VECTORIZER_DEB_VERSION="${PGEDGE_VECTORIZER_VERSION}"
if command -v apt-get &>/dev/null; then
    if [[ "$PGEDGE_VECTORIZER_BUILDNUM" == *_* ]]; then
        PGEDGE_VECTORIZER_PRETAG="${PGEDGE_VECTORIZER_BUILDNUM%%_*}"
        export PGEDGE_VECTORIZER_DEB_VERSION="${PGEDGE_VECTORIZER_VERSION}~${PGEDGE_VECTORIZER_PRETAG}"
        PGEDGE_VECTORIZER_BUILDNUM="${PGEDGE_VECTORIZER_BUILDNUM##*_}"
    fi
fi

# release.yml stages the source tarball built from THIS run's checkout here.
export ARTIFACT_DIR="${ARTIFACT_DIR:-$(pwd)/release-artifacts}"
export SRC_TARBALL="pgedge-vectorizer-${PGEDGE_VECTORIZER_VERSION}.tar.gz"

# Prefer the workflow-staged tarball (so branch / simulate_tag runs build the
# exact commit under test and need no network). The PGEDGE_VECTORIZER_BRANCH
# clone is an opt-in fallback for local builds: set
# PGEDGE_VECTORIZER_ALLOW_CLONE_FALLBACK=1.
stage_source() {
  local dest="$1"
  if [ -f "${ARTIFACT_DIR}/${SRC_TARBALL}" ]; then
    echo "Staging ${SRC_TARBALL} from ${ARTIFACT_DIR}"
    cp "${ARTIFACT_DIR}/${SRC_TARBALL}" "${dest}"
  elif [ -z "${PGEDGE_VECTORIZER_ALLOW_CLONE_FALLBACK:-}" ]; then
    # A staged tarball is required by default: cloning PGEDGE_VECTORIZER_BRANCH
    # instead would ship a package built from a different commit than
    # COMPONENT_VERSION claims.
    echo "::error::${ARTIFACT_DIR}/${SRC_TARBALL} not found. release.yml stages it with git archive; for a local build, stage it yourself or set PGEDGE_VECTORIZER_ALLOW_CLONE_FALLBACK=1 to clone ${PGEDGE_VECTORIZER_BRANCH} instead." >&2
    return 1
  else
    echo "Fetching pgedge-vectorizer source code (${PGEDGE_VECTORIZER_BRANCH})"
    rm -rf "pgedge-vectorizer-${PGEDGE_VECTORIZER_VERSION}"
    git clone --depth=1 --branch "$PGEDGE_VECTORIZER_BRANCH" "$PG_PGEDGE_VECTORIZER_REPO" "pgedge-vectorizer-${PGEDGE_VECTORIZER_VERSION}"
    rm -rf "pgedge-vectorizer-${PGEDGE_VECTORIZER_VERSION}/.git"
    tar -czf "${SRC_TARBALL}" "pgedge-vectorizer-${PGEDGE_VECTORIZER_VERSION}"
    rm -rf "pgedge-vectorizer-${PGEDGE_VECTORIZER_VERSION}"
    mv "${SRC_TARBALL}" "${dest}"
  fi
}

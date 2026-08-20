#!/usr/bin/env bash
# build_and_publish.sh
# Automates:
# 1) Copy ersec_1.0-1/usr/local/bin/ersec -> /usr/local/bin/ersec and make executable
# 2) Re-copy /usr/local/bin/ersec back into the repo package folder
# 3) Build the Debian package with dpkg-deb --build ersec_1.0-1
# 4) Run dpkg-scanpackages . /dev/null > Packages, gzip Packages, generate Release and GPG InRelease signatures
# 5) Git add/commit/push to origin main
#
# Usage: run from repository root: ./build_and_publish.sh
# Requirements: sudo for copying to /usr/local/bin, dpkg-deb, dpkg-scanpackages, gzip, gpg, git.
set -euo pipefail

# Configuration
DEB_DIR="ersec_1.0-1"
REPO_BIN_PATH="${DEB_DIR}/usr/local/bin/ersec"
SYSTEM_BIN_PATH="/usr/local/bin/ersec"
GPG_KEY="${GPG_KEY:-}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-main}"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

err() {
  echo "[$(timestamp)] ERROR: $*" >&2
}

info() {
  echo "[$(timestamp)] INFO: $*"
}

die() {
  err "$@"
  exit 1
}

# Ensure we're in repo root and DEB_DIR exists
if [ ! -d "${DEB_DIR}" ]; then
  die "Debian package directory '${DEB_DIR}' not found in $(pwd). Run this script from the repository root."
fi

if [ ! -f "${REPO_BIN_PATH}" ]; then
  die "Source binary '${REPO_BIN_PATH}' not found."
fi

# Step 1: Copy to /usr/local/bin and make executable
info "Copying ${REPO_BIN_PATH} -> ${SYSTEM_BIN_PATH} (requires sudo)"
if sudo cp --preserve=mode,ownership,timestamps "${REPO_BIN_PATH}" "${SYSTEM_BIN_PATH}"; then
  info "Copied to ${SYSTEM_BIN_PATH}"
else
  die "Failed to copy to ${SYSTEM_BIN_PATH}"
fi

info "Setting executable permission on ${SYSTEM_BIN_PATH}"
if sudo chmod +x "${SYSTEM_BIN_PATH}"; then
  info "Set +x on ${SYSTEM_BIN_PATH}"
else
  die "Failed to chmod ${SYSTEM_BIN_PATH}"
fi

# Step 2: Re-copy back into repo package folder (preserve the system-installed copy)
info "Re-copying ${SYSTEM_BIN_PATH} -> ${REPO_BIN_PATH} (using sudo to read system file if needed)"
if sudo cp --preserve=mode,ownership,timestamps "${SYSTEM_BIN_PATH}" "${REPO_BIN_PATH}"; then
  info "Copied back into package folder: ${REPO_BIN_PATH}"
else
  die "Failed to copy back into package folder"
fi

# Ensure repo copy is owned by current user so subsequent packaging/git operations work
CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"
if sudo chown "${CURRENT_UID}:${CURRENT_GID}" "${REPO_BIN_PATH}"; then
  info "Adjusted ownership of ${REPO_BIN_PATH} to $(id -un):$(id -gn)"
else
  err "Failed to chown ${REPO_BIN_PATH}; continuing may still work if permissions allow."
fi

# Step 3: Build Debian package
info "Building Debian package from '${DEB_DIR}'"
if dpkg-deb --build "${DEB_DIR}"; then
  info "dpkg-deb completed. Generated ${DEB_DIR}.deb"
else
  die "dpkg-deb build failed"
fi

# Step 4: Create Packages and compress, then generate Release and signatures
info "Generating Packages file with dpkg-scanpackages"
if command -v dpkg-scanpackages >/dev/null 2>&1; then
  dpkg-scanpackages . /dev/null > Packages
  info "Packages file generated"
else
  die "dpkg-scanpackages not found. Install dpkg-dev package."
fi

info "Compressing Packages -> Packages.gz (keeping original)"
gzip -k -f Packages
info "Packages.gz created"

# Generate Release. Prefer apt-ftparchive if available for a proper Release file
if command -v apt-ftparchive >/dev/null 2>&1; then
  info "Generating Release using apt-ftparchive"
  apt-ftparchive release . > Release
else
  info "apt-ftparchive not found; creating minimal Release file"
  cat > Release <<'EOF'
Archive: local
Component: main
Origin: local
Label: local
Architecture: amd64
EOF
fi

info "Release file created"

# Generate GPG signatures: Release.gpg (detached) and InRelease (clear-signed)
if command -v gpg >/dev/null 2>&1; then
  GPG_OPTS=(--batch --yes)
  if [ -n "${GPG_KEY}" ]; then
    GPG_OPTS+=( -u "${GPG_KEY}" )
    info "Using GPG key: ${GPG_KEY}"
  else
    info "No GPG_KEY provided: using default gpg key"
  fi

  info "Creating detached signature Release.gpg"
  if gpg "${GPG_OPTS[@]}" --output Release.gpg --detach-sign Release; then
    info "Release.gpg created"
  else
    err "Failed to create Release.gpg"
  fi

  info "Creating clear-signed InRelease (inline signature)"
  if gpg "${GPG_OPTS[@]}" --clearsign --output InRelease Release; then
    info "InRelease created"
  else
    err "Failed to create InRelease"
  fi
else
  err "gpg not found; skipping signatures"
fi

# Step 5: Git add, commit, push
info "Staging changes for commit"
git add .

COMMIT_MSG="chore(release): build deb and repo artifacts - $(timestamp)"
# Only commit if there are staged changes
if git diff --cached --quiet; then
  info "No changes to commit"
else
  info "Committing changes: ${COMMIT_MSG}"
  if git commit -m "${COMMIT_MSG}"; then
    info "Committed"
  else
    err "git commit failed"
  fi
fi

info "Pushing to ${GIT_REMOTE} ${GIT_BRANCH}"
if git push "${GIT_REMOTE}" "${GIT_BRANCH}"; then
  info "Pushed to ${GIT_REMOTE}/${GIT_BRANCH}"
else
  err "git push failed. Check remote/authentication and try 'git push ${GIT_REMOTE} ${GIT_BRANCH}' manually."
  exit 0
fi

info "Build and publish steps completed."

#!/bin/bash
# SessionStart hook for Claude Code on the web: build vsearch so the binary is
# ready for the session (the external test suite resolves it via PATH).
set -euo pipefail

# Only needed in the remote (web) environment.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

# vsearch builds with autotools, and the committed build files (configure,
# Makefile.in, ...) are authoritative: AM_MAINTAINER_MODE is disabled, so a
# plain configure + make never regenerates them and no specific autoconf/
# automake version is required. Do NOT run ./autogen.sh here.
if [ ! -f Makefile ]; then
  ./configure CFLAGS="-O2" CXXFLAGS="-O2"
fi

# ARFLAGS="cr" is required on the make line by this project's archive step.
make ARFLAGS="cr"

# Expose the freshly built binary for the rest of the session; the test suite
# (frederic-mahe/vsearch-tests) resolves vsearch via PATH.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$PWD/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

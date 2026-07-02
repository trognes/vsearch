#!/bin/bash
# SessionStart hook for Claude Code on the web: build vsearch so the binary is
# ready for the session (the external test suite resolves it via PATH).
#
# Runs asynchronously: the session starts immediately and the build proceeds in
# the background. This avoids blocking startup on a ~2-3 min build, at the cost
# of a brief window where bin/vsearch may not exist yet (the build finishes
# soon after). On a cached container the build is a fast no-op.
set -euo pipefail

# Only needed in the remote (web) environment. Return before the async
# directive so local sessions just no-op.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Must be the first line of stdout: tells the harness to run the rest in the
# background. asyncTimeout is generous relative to a cold full build.
echo '{"async": true, "asyncTimeout": 300000}'

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Put bin/ on PATH up front. The path is known before the build finishes, and
# writing it early (rather than after `make`) maximizes the chance the session
# picks it up despite the async timing. The test suite
# (frederic-mahe/vsearch-tests) resolves vsearch via PATH.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$PWD/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

# vsearch builds with autotools, and the committed build files (configure,
# Makefile.in, ...) are authoritative: AM_MAINTAINER_MODE is disabled, so a
# plain configure + make never regenerates them and no specific autoconf/
# automake version is required. Do NOT run ./autogen.sh here.
if [ ! -f Makefile ]; then
  ./configure CFLAGS="-O2" CXXFLAGS="-O2"
fi

# ARFLAGS="cr" is required on the make line by this project's archive step.
make ARFLAGS="cr"

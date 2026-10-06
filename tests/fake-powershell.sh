#!/usr/bin/env bash
set -u

printf '%s\n' "$*" >>"${FAKE_MUSE_PS_CALLS:?}"
cat "${FAKE_MUSE_PS_FIXTURE:?}"

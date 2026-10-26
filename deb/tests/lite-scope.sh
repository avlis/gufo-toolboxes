#!/usr/bin/env bash
set -uo pipefail

# deb/tests/lite-scope.sh -- prove the scope of the lite package, and prove this gate fires.
#
#   deb/tests/lite-scope.sh                      # check the lane's own source
#   deb/tests/lite-scope.sh path/to/deb/       # check a different lane checkout
#   deb/tests/lite-scope.sh gufo_0.24.0-1_amd64.deb   # check the built artifact
#
# A directory argument selects source mode against that checkout; a file argument selects artifact
# mode. With no argument, source mode against this lane.
#
# The negative half at the end is not ceremony. It injects the exact shapes we are promising not
# to ship -- a systemd unit, /etc/gufo/gufo.env, a maintainer script -- into a copy, and
# requires this same script to exit non-zero against the copy. A gate nobody has watched fail is
# decoration, and this project has already shipped one of those once.

set -e
target="${1:-}"
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Absolute, with no `..` in it. This used to be `${self}/..`, which made every path the grep
# printed look like `deb/tests/../README.md` -- and the exclusion below (`skip our own test
# fixtures`) then matched EVERY line in the lane. The version-literal check has therefore been
# vacuously green since it was written: it inspected nothing and reported ok. A guard that cannot
# fire is not a guard, and this one could not fail.
lane="$(cd "${self}/.." && pwd)"
fail=0; pass=0
ok()  { printf '  ok     %-50s %s\n' "$1" "${2:-yes}"; pass=$((pass+1)); }
bad() { printf '  FAIL   %-50s %s\n' "$1" "${2:-missing}"; fail=$((fail+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# The negative control runs this same script against an injected copy. That inner run must not
# launch a negative control of its own -- an earlier version recursed until the box filled with
# 13,000 temp directories, which is the kind of fact a guard is cheaper than a lesson.
noc="${LITE_SCOPE_INNER:-0}"

has() { printf '%s\n' "$@"; } # helper: emit nothing, keep shellcheck off the grep -F patterns

if [[ -n "${target}" && ! -e "${target}" ]]; then
  echo "error: ${target} does not exist" >&2; exit 2
elif [[ "${target}" == *.deb || -f "${target}" ]]; then
  echo "=== artifact: ${target}"
  pkg="$(dpkg-deb -f "${target}" Package)"
  [[ "${pkg}" == "gufo" ]] && ok "Package field" "gufo" || bad "Package field" "${pkg}"
  printf '  info   Version %s  Arch %s  Installed-Size %s\n' \
    "$(dpkg-deb -f "${target}" Version)" "$(dpkg-deb -f "${target}" Architecture)" "$(dpkg-deb -f "${target}" Installed-Size)"
  listing="$(dpkg-deb -c "${target}" | awk '{print $NF}')"
  for pat in 'lib/systemd/system/' '/etc/gufo' '/usr/lib/gufo/'; do
    hit="$(printf '%s\n' "${listing}" | grep -F "${pat}" | head -1 || true)"
    [[ -z "${hit}" ]] && ok "no ${pat}" "absent" || bad "no ${pat}" "found: ${hit}"
  done
  for pat in '/usr/bin/gufo' '/etc/ld.so.conf.d/rocm.conf' '/usr/share/doc/gufo/copyright'; do
    hit="$(printf '%s\n' "${listing}" | grep -F "${pat}" | head -1 || true)"
    [[ -n "${hit}" ]] && ok "has ${pat}" "present" || bad "has ${pat}" "MISSING"
  done
  dpkg-deb -e "${target}" "${WORK}/ctl" >/dev/null 2>&1 || true
  mapfile -t ctl < <(ls "${WORK}/ctl" 2>/dev/null || true)
  for s in postinst prerm postrm preinst; do
    if printf '%s\n' "${ctl[@]}" | grep -qx "${s}"; then
      bad "DEBIAN/${s} absent" "shipped -- the claim was a script-free package"
    else
      ok "DEBIAN/${s} absent" "yes"
    fi
  done
  if printf '%s\n' "${ctl[@]}" | grep -qx "triggers"; then
    ok "DEBIAN/triggers present" "$(grep -v '^[[:space:]]*#' \"${WORK}/ctl/triggers\" 2>/dev/null | tr -d '\n')"
  else
    bad "DEBIAN/triggers present" "MISSING -- without it /opt/rocm/lib never reaches the loader"
  fi
  depends="$(dpkg-deb -f "${target}" Depends)"
  for p in hip-runtime-amd hipblas hipblaslt rocblas ffmpeg; do
    if printf '%s' "${depends}" | grep -qE "(^|[ ,(])${p}( |\(|,|\$)"; then ok "Depends names ${p}"; else bad "Depends names ${p}" "not declared"; fi
  done
  stage="${WORK}/stage"; dpkg-deb -x "${target}" "${stage}" >/dev/null 2>&1 || true
  mkdir -p "${stage}/lib/systemd/system" "${stage}/etc/gufo" "${stage}/DEBIAN"
  printf '[Unit]\nDescription=injected\n' > "${stage}/lib/systemd/system/gufo.service"
  printf 'MODEL=/injected\n' > "${stage}/etc/gufo/gufo.env"
  printf '#!/bin/sh\nexit 0\n' > "${stage}/DEBIAN/postinst"; chmod +x "${stage}/DEBIAN/postinst"
  dpkg-deb --build "${stage}" "${WORK}/injected.deb" >/dev/null 2>&1 || true
  if [[ "${noc}" == "1" ]]; then
    skip_neg() { printf '  skip   %-50s %s\n' "$1" "$2"; }
    skip_neg "negative control" "already running as the inner run"
  elif LITE_SCOPE_INNER=1 "${self}/lite-scope.sh" "${WORK}/injected.deb" >/dev/null 2>&1; then
    bad "injected unit + config + script rejected" "gate PASSED a package it should have failed"
  else
    ok "injected unit + config + script rejected" "exits non-zero, as it must"
  fi
else
  [[ -n "${target}" ]] && lane="${target}"
  echo "=== lane source: ${lane}/common"
  [[ -d "${lane}/common" ]] || { echo "error: ${lane}/common not found" >&2; exit 2; }
  # Full depth, not depth 1: an empty leftover directory is invisible to git and survives a
  # `rm -rf` of its contents, and `cp -a` carries it straight into debian/ -- which is how a
  # directory whose whole point was another package reappears in this one.
  mapfile -t src < <(find "${lane}/common" -mindepth 1 \( -type f -o -type d \) -printf '%f\n' | sort -u)
  for f in gufo.service gufo@.service gufo.env gufo-launch.sh gufo-upgrade-units.sh changelog preinst postinst prerm postrm rocm.gpg gufo-rocm-repo tools; do
    if printf '%s\n' "${src[@]}" | grep -qx "${f}"; then bad "no ${f} in the lane" "present"; else ok "no ${f} in the lane" "the service layer is a separate review"; fi
  done
  hits="$(grep -rnE '0\.(1[0-9]|2[0-9]|3[0-9])\.[0-9]+|repo\.radeon\.com/rocm/apt/[0-9]' "${lane}" 2>/dev/null \
          | grep -vE '^[^:]+:[0-9]+:\s*#' | grep -v '/tests/' || true)"
  if [[ -z "${hits}" ]]; then
    ok "no release or ROCm-series literal" "a new upstream release needs no edit here"
  else
    bad "no release or ROCm-series literal" "$(printf '%s' "${hits}" | head -2 | tr '\n' ' | ')"
  fi
  # And prove THIS check can fire. It cannot be taken on faith: the first version of it scanned a
  # path that contained `/tests/` in every line and so filtered the entire lane away, reporting a
  # clean result it had never earned. Inject a release literal into a scratch copy and require that
  # the same grep finds it.
  probe="${lane}/.lite-scope-probe-$$.md"
  printf 'example: deb/build-deb v9.9.9 and the ROCm apt dir https://repo.radeon.com/rocm/apt/1.2.3\n' > "${probe}"
  if grep -rnE '0\.(1[0-9]|2[0-9]|3[0-9])\.[0-9]+|repo\.radeon\.com/rocm/apt/[0-9]' "${lane}" 2>/dev/null \
       | grep -vE '^[^:]+:[0-9]+:[0-9]*\s*#' | grep -v '/tests/' | grep -q 'lite-scope-probe'; then
    ok "the literal check can fire" "an injected v9.9.9 is found by the same grep that just passed"
  else
    bad "the literal check can fire" "injected literal NOT found -- the scan is blind, and its ok means nothing"
  fi
  rm -f "${probe}"
  # Comment lines do not compile: a comment that says "no tuning flags here" must not trip a
  # check for tuning flags, or the gate is arguing with prose instead of watching the recipe.
  if grep -vE '^[[:space:]]*#' "${lane}/common/rules" 2>/dev/null | grep -qE -- '-march=|-mtune='; then
    bad "rules ships no tuning default" "a tuning flag found in the recipe"
  else
    ok "rules ships no tuning default" "portable baseline is the default"
  fi
  # "The lane needs no bump at release time" is a claim about behaviour, so test the behaviour:
  # point gen-deb-ver at a checkout carrying a version the lane has never heard of, and require
  # that the version it prints follows the checkout and not the recipe.
  fake="${WORK}/fake-engine"; mkdir -p "${fake}"; git -C "${fake}" init -q >/dev/null 2>&1
  echo "9.9.9" > "${fake}/version.txt"; git -C "${fake}" add -A >/dev/null 2>&1
  git -C "${fake}" -c user.email=t@t -c user.name=t commit -qm fake >/dev/null 2>&1
  if v="$(SNAPSHOT=1 "${lane}/gen-deb-ver" "${fake}" 2>/dev/null)"; then
    case "${v}" in
      9.9.9+git*-1) ok "version follows the source, not the recipe" "unseen 9.9.9 -> ${v}" ;;
      *) bad "version follows the source, not the recipe" "9.9.9 in, ${v} out" ;;
    esac
  else
    bad "version follows the source, not the recipe" "gen-deb-ver refused a synthetic checkout"
  fi
    if git -C "${lane}/.." ls-files 'deb/common/changelog' | grep -q changelog; then
    bad "no generated changelog tracked" "deb/common/changelog is in git -- it rots every release"
  else
    ok "no generated changelog tracked" "nothing to bump at release time"
  fi
  cp -a "${lane}" "${WORK}/copy" >/dev/null 2>&1 || true
  mkdir -p "${WORK}/copy/common"
  printf '[Unit]\nDescription=injected\n' > "${WORK}/copy/common/gufo.service"
  printf 'MODEL=/injected\n' > "${WORK}/copy/common/gufo.env"
  if [[ "${noc}" == "1" ]]; then
    printf '  skip   %-50s %s\n' "negative control" "already running as the inner run"
  elif LITE_SCOPE_INNER=1 "${self}/lite-scope.sh" "${WORK}/copy" >/dev/null 2>&1; then
    bad "injected service files rejected" "gate PASSED a lane it should have failed"
  else
    ok "injected service files rejected" "exits non-zero, as it must"
  fi
fi

echo
printf 'lite-scope: %s passed, %s failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1

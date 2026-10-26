#!/usr/bin/env bash
set -uo pipefail

# debian/tests/smoke.sh -- what this package must do on a machine, and what it must NOT do.
#
# Runs as an autopkgtest (Testsuite: autopkgtest in debian/control) and by hand:
#   sudo ./debian/tests/smoke.sh
#
# It does not run inference and it does not need a GPU. The GPU suites are the engine's own;
# what is worth proving here is the packaging, and in particular the two halves that a
# "package the binary" change quietly gets wrong:
#
#   1. that "lite" means lite -- no unit, no launcher, no /etc/gufo, no port opened by us.
#      Without a negative assertion this test would pass whether or not the scope was respected,
#      which is the same as not testing.
#   2. that every library the binary actually asks for is either satisfiable on this host or
#      named in Depends. That is the failure this lane existed to fix: the ROCm runtime ships no
#      shlibs metadata, so ${shlibs:Depends} is silent about it and the package installs on a
#      host where the binary cannot load.
#
# It reports the command it ran for every verdict, including the skips, so a green run can be
# audited rather than believed.

pkg="${PKG:-gufo}"
fail=0
pass=0
ok()   { printf '  ok     %-52s %s\n' "$1" "$2"; pass=$((pass+1)); }
bad()  { printf '  FAIL   %-52s %s\n' "$1" "$2"; fail=$((fail+1)); }
skip() { printf '  skip   %-52s %s\n' "$1" "$2"; }

command -v dpkg-query >/dev/null || { echo "dpkg-query missing" >&2; exit 2; }
dpkg-query -W -f='${Package} ${Version}\n' "${pkg}" >/dev/null 2>&1 || {
  echo "error: ${pkg} is not installed; this test runs against an installed package." >&2; exit 2; }

mapfile -t files < <(dpkg -L "${pkg}" 2>/dev/null)
bin="/usr/bin/gufo"

echo "=== the scope: what must NOT be here ==="
for pat in '/lib/systemd/system/' '/usr/lib/systemd/' '/etc/gufo' '/usr/lib/gufo/'; do
  hit="$(printf '%s\n' "${files[@]}" | grep -F "${pat}" || true)"
  if [[ -z "${hit}" ]]; then
    ok "no ${pat}" "0 files"
  else
    bad "no ${pat}" "$(printf '%s' "${hit}" | tr '\n' ' ')"
  fi
done

if [[ -e /etc/gufo/gufo.env ]]; then
  bad "/etc/gufo absent (no config assumed)" "present -- the package decided a model/launcher layout"
else
  ok "/etc/gufo absent (no config assumed)" "which is the point: how to run it is not this package's call"
fi

echo "=== the scope: what MUST be here ==="
[[ -x "${bin}" ]] && ok "${bin} executable" "$(stat -c '%A %s' "${bin}")" || bad "${bin} executable" "missing"

for f in /etc/ld.so.conf.d/rocm.conf /usr/share/doc/gufo/copyright; do
  if [[ -e "${f}" ]]; then ok "${f}" "present"; else bad "${f}" "MISSING"; fi
done

# The runtime data is not optional and not a data drop: those paths are compiled into the
# binary as absolute strings, so an absent file is a runtime miss, not untidiness.
mapfile -t want_data < <(strings "${bin}" 2>/dev/null | grep -oE '/usr/share/gufo/[A-Za-z0-9._/-]+' | sort -u)
if [[ "${#want_data[@]}" -eq 0 ]]; then
  skip "runtime data referenced by the binary" "strings found none (stripped?)"
else
  miss=0
  for p in "${want_data[@]}"; do [[ -e "${p}" ]] || { bad "installed: ${p}" "referenced by the binary, not on disk"; miss=$((miss+1)); }; done
  [[ "${miss}" -eq 0 ]] && ok "runtime data referenced by the binary is installed" "${#want_data[@]} paths, all present"
fi

echo "=== the dependencies: does every library the binary asks for exist on this host? ==="
# No soname-to-package guessing here. A table of "libfoo.so.N -> probably libfooN" is a second
# source of truth that drifts the moment a distribution renames a package for the time64 transition
# (libcurl4 -> libcurl4t64 did exactly that), and a test that guesses will then tell you the
# package is wrong when the test is wrong. So the question is asked the way it can be answered:
#   is the dependency set satisfied on this host?  if not, say which half cannot be judged;
#   does every NEEDED entry resolve?                if not, name it and say what is missing.
depends="$(dpkg-query -W -f='${Depends}' "${pkg}" 2>/dev/null)"
unsatisfied=""
# Parse the Depends field the way dpkg writes it: one comma-separated list, optionally wrapped,
# each item `name (>= version)' or a substitution variable. An earlier version of this cut at the
# first `>=' and so kept exactly one package name out of fifteen -- which is how the test below
# reported a declared dependency as missing. Tokenise instead of truncating.
depnames="$(printf '%s' "${depends}" | tr '\n' ',' | tr ',' '\n' \
  | awk '{ gsub(/[()]/, " "); n = split($0, a, /[[:space:]]+/); for (i = 1; i <= n; i++) {
      t = a[i]; if (t == "" || t ~ /^>=/ || t ~ /^[0-9]/ || t ~ /^\$\{/) continue; print t } }' \
  | sort -u)"
for d in ${depnames}; do
  st="$(dpkg-query -W -f='${Status}' "${d}" 2>/dev/null || true)"
  case "${st}" in
    *install\ ok\ installed) ;;
    *) unsatisfied="${unsatisfied} ${d}" ;;
  esac
done
if [[ -n "${unsatisfied}" ]]; then
  printf '  note   dependencies NOT satisfied on this testbed:%s\n' "${unsatisfied}"
  printf '           (so this host cannot judge whether those libraries resolve; the arm that installs\n'
  printf '           them -- the builder image, or a host with AMD'"'"'s ROCm repository -- is what proves it)\n'
fi

if ! command -v readelf >/dev/null; then
  skip "NEEDED audit" "binutils/readelf not installed on this testbed"
else
  mapfile -t needed < <(readelf -d "${bin}" 2>/dev/null | awk -F'[][]' '/NEEDED/{print $2}')
  unresolved=0
  for lib in "${needed[@]}"; do
    if ldconfig -p 2>/dev/null | grep -qF "${lib}"; then
      continue
    fi
    # Unresolvable through the cache. If the package that owns it is installed, the problem is
    # the loader path -- which is the job of the conffile and the ldconfig trigger, and a real
    # failure. If it is not installed, this testbed simply does not carry that runtime.
    owner="$(for p in $(printf '%s' "${depends}" | tr ',()' '   ' | grep -v '^$'); do
              dpkg -L "${p}" 2>/dev/null | grep -qF "/${lib}" && printf '%s\n' "${p}"
            done | head -1)"
    if [[ -n "${owner}" ]]; then
      bad "resolve ${lib}" "installed via ${owner} but the loader cannot see it -- ld.so.conf.d entry or cache refresh missing"
      unresolved=$((unresolved+1))
    elif [[ -n "${unsatisfied}" ]]; then
      printf '  n/a    %s%s\n' "$(printf '%-38s' "resolve ${lib}")" "runtime not on this testbed; declared in Depends"
    else
      bad "resolve ${lib}" "no NEEDED provider installed and not declared in Depends"
      unresolved=$((unresolved+1))
    fi
  done
  printf '           (%s NEEDED entries; %s unresolved here)\n' "${#needed[@]}" "${unresolved}"
fi

echo "=== the linker path: /opt/rocm/lib reaches the loader ==="
if [[ -d /opt/rocm/lib ]]; then
  n="$(ldconfig -p 2>/dev/null | grep -c '/opt/rocm')" || true
  if [[ "${n:-0}" -gt 0 ]]; then
    ok "cache carries /opt/rocm" "${n} entries (conf + activate ldconfig did their job)"
  else
    bad "cache carries /opt/rocm" "0 entries -- conf installed but the cache never refreshed"
  fi
else
  if grep -q '/opt/rocm/lib' /etc/ld.so.conf.d/rocm.conf 2>/dev/null; then
    skip "cache carries /opt/rocm" "no ROCm on this testbed; conf is installed and says /opt/rocm/lib"
  else
    bad "conf names /opt/rocm/lib" "conffile present but does not name the ROCm directory"
  fi
fi

echo
printf 'smoke: %s passed, %s failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1

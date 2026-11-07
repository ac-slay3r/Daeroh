#!/usr/bin/env bash
# Focused regression test for the Daeroh Spec 047 emulator guard.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/tool/qa/spec047_emulator_guard.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/daeroh-spec047-guard.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

cat >"$scratch/adb" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  'devices')
    printf 'List of devices attached\nemulator-5554\tdevice\n'
    ;;
  '-s emulator-5554 get-state') printf 'device\n' ;;
  '-s emulator-5554 emu avd name') printf 'Daeroh_API37_x86_64\nOK\n' ;;
  '-s emulator-5554 shell getprop ro.build.version.sdk') printf '37\n' ;;
  '-s emulator-5554 shell getprop ro.kernel.qemu') printf '%s\n' "${FAKE_QEMU:-1}" ;;
  '-s emulator-5554 shell getprop sys.boot_completed') printf '1\n' ;;
  '-s emulator-5554 shell pm list packages cool.n0thing.daeroh.qa')
    printf 'package:cool.n0thing.daeroh.qa\n'
    ;;
  '-s emulator-5554 shell dumpsys package cool.n0thing.daeroh.qa')
    printf 'versionName=0.1.8-qa\nversionCode=9 minSdk=29\n'
    ;;
  *) printf 'unexpected adb call: %s\n' "$*" >&2; exit 64 ;;
esac
EOF
chmod +x "$scratch/adb"

output="$(ADB_BIN="$scratch/adb" "$guard" doctor)"
printf '%s\n' "$output" | grep -F 'Guard OK: serial=emulator-5554 avd=Daeroh_API37_x86_64 API=37 qemu=1' >/dev/null
printf '%s\n' "$output" | grep -F 'Paquete QA: package:cool.n0thing.daeroh.qa version=0.1.8-qa code=9' >/dev/null

for script in \
  tool/qa/resilience_smoke.sh \
  tool/qa/verify_qa_profile_network_policy.sh \
  tool/qa/perfetto/common.sh \
  scripts/voice-log.sh; do
  ! grep -F 'dev.xpetalab.hermesconsole.qa' "$repo_root/$script" >/dev/null
  grep -F 'cool.n0thing.daeroh.qa' "$repo_root/$script" >/dev/null
done
! grep -F 'dev.xpetalab.hermesconsole' "$repo_root/tool/qa/release_rehearsal.sh" >/dev/null
grep -F 'cool.n0thing.daeroh' "$repo_root/tool/qa/release_rehearsal.sh" >/dev/null

if ANDROID_SERIAL='physical-serial' ADB_BIN="$scratch/adb" "$guard" doctor >/dev/null 2>&1; then
  printf 'guard accepted a non-emulator serial\n' >&2
  exit 1
fi
if FAKE_QEMU=0 ADB_BIN="$scratch/adb" "$guard" doctor >/dev/null 2>&1; then
  printf 'guard accepted a non-emulator target\n' >&2
  exit 1
fi

printf 'Spec 047 guard and QA helpers use the current Daeroh API-37 target\n'

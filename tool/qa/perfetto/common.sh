#!/usr/bin/env bash

set -euo pipefail

readonly PERFETTO_PACKAGE='cool.n0thing.daeroh.qa'
readonly PERFETTO_DEFAULT_SERIAL=''

# These sources are the minimum evidence gate. A capture must not continue if
# the connected device cannot provide one of them.
readonly -a PERFETTO_REQUIRED_SOURCES=(
  'linux.ftrace'
  'linux.process_stats'
  'android.surfaceflinger.frametimeline'
  'android.cpu_per_uid'
  'track_event'
)

# These sources enrich the same capture but depend on Android/kernel support.
# Their absence is reported explicitly and never converted into a PASS.
readonly -a PERFETTO_SUPPLEMENTAL_SOURCES=(
  'android.surfaceflinger.frame'
  'android.app_wakelocks'
  'android.kernel_wakelocks'
  'android.power'
  'linux.sysfs_power'
)

readonly -a PERFETTO_ALLOWED_SOURCES=(
  "${PERFETTO_REQUIRED_SOURCES[@]}"
  "${PERFETTO_SUPPLEMENTAL_SOURCES[@]}"
)

perfetto_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

perfetto_validate_serial() {
  local serial="$1"
  [[ -n "$serial" ]] || perfetto_die 'el serial del dispositivo esta vacio'
  [[ "$serial" =~ ^[A-Za-z0-9._:-]+$ ]] ||
    perfetto_die "serial no valido: ${serial}"
}

perfetto_validate_uint() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] ||
    perfetto_die "${label} debe ser un entero no negativo: ${value}"
}

perfetto_metadata_value() {
  local metadata_path="$1"
  local key="$2"
  awk -v prefix="${key}=" '
    index($0, prefix) == 1 {
      print substr($0, length(prefix) + 1)
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$metadata_path"
}

perfetto_trace_processor_lock_value() {
  local key="$1"
  perfetto_metadata_value "${SCRIPT_DIR}/trace_processor.lock" "$key"
}

perfetto_validate_trace_processor_lock() {
  local trace_lock_file="${SCRIPT_DIR}/trace_processor.lock"
  [[ -r "$trace_lock_file" ]] ||
    perfetto_die "falta lock oficial: ${trace_lock_file}"

  local release
  local release_commit
  local schema_version
  local project
  local release_tag_object
  local bootstrap_manifest_url
  local bootstrap_manifest_sha256
  local bootstrap_manifest_declared_release
  local artifact_provenance
  local artifact_platform
  local artifact_file
  local artifact_url
  local artifact_size
  local artifact_sha256
  schema_version="$(
    perfetto_trace_processor_lock_value schema_version || true
  )"
  project="$(perfetto_trace_processor_lock_value project || true)"
  release="$(perfetto_trace_processor_lock_value release || true)"
  release_tag_object="$(
    perfetto_trace_processor_lock_value release_tag_object || true
  )"
  release_commit="$(
    perfetto_trace_processor_lock_value release_commit || true
  )"
  bootstrap_manifest_url="$(
    perfetto_trace_processor_lock_value bootstrap_manifest_url || true
  )"
  bootstrap_manifest_sha256="$(
    perfetto_trace_processor_lock_value bootstrap_manifest_sha256 || true
  )"
  bootstrap_manifest_declared_release="$(
    perfetto_trace_processor_lock_value \
      bootstrap_manifest_declared_release || true
  )"
  artifact_provenance="$(
    perfetto_trace_processor_lock_value artifact_provenance || true
  )"
  artifact_platform="$(
    perfetto_trace_processor_lock_value artifact_platform || true
  )"
  artifact_file="$(
    perfetto_trace_processor_lock_value artifact_file || true
  )"
  artifact_url="$(perfetto_trace_processor_lock_value artifact_url || true)"
  artifact_size="$(
    perfetto_trace_processor_lock_value artifact_size_bytes || true
  )"
  artifact_sha256="$(
    perfetto_trace_processor_lock_value artifact_sha256 || true
  )"

  [[ "$schema_version" == '1' ]] ||
    perfetto_die 'schema_version no soportado en trace_processor.lock'
  [[ "$project" == 'google_perfetto' ]] ||
    perfetto_die 'project invalido en trace_processor.lock'
  [[ "$release" =~ ^v[0-9]+([.][0-9]+)+$ ]] ||
    perfetto_die 'release invalida en trace_processor.lock'
  [[ "$release_tag_object" =~ ^[a-f0-9]{40}$ ]] ||
    perfetto_die 'release_tag_object invalido en trace_processor.lock'
  [[ "$release_commit" =~ ^[a-f0-9]{40}$ ]] ||
    perfetto_die 'release_commit invalido en trace_processor.lock'
  [[ "$bootstrap_manifest_url" == \
    "https://raw.githubusercontent.com/google/perfetto/${release}/tools/trace_processor" ]] ||
    perfetto_die 'bootstrap_manifest_url no coincide con el tag fijado'
  [[ "$bootstrap_manifest_sha256" =~ ^[a-f0-9]{64}$ ]] ||
    perfetto_die 'bootstrap_manifest_sha256 invalido en trace_processor.lock'
  [[ "$bootstrap_manifest_declared_release" == 'v56.1' ]] ||
    perfetto_die 'release declarada por el bootstrap no auditada'
  [[ "$artifact_provenance" == \
    'direct_luci_release_path_and_pinned_digest' ]] ||
    perfetto_die 'artifact_provenance invalido en trace_processor.lock'
  [[ "$artifact_platform" == 'linux-amd64' ]] ||
    perfetto_die 'solo se admite el lock linux-amd64 revisado'
  [[ "$artifact_file" == \
    "trace_processor_shell-${release}-${artifact_platform}" ]] ||
    perfetto_die 'artifact_file no coincide con release/plataforma fijados'
  [[ "$artifact_url" == \
    "https://commondatastorage.googleapis.com/perfetto-luci-artifacts/${release}/${artifact_platform}/trace_processor_shell" ]] ||
    perfetto_die 'artifact_url no coincide con la ruta LUCI fijada'
  perfetto_validate_uint artifact_size_bytes "$artifact_size"
  [[ "$artifact_sha256" =~ ^[a-f0-9]{64}$ ]] ||
    perfetto_die 'artifact_sha256 invalido en trace_processor.lock'
}

perfetto_default_trace_processor() {
  perfetto_validate_trace_processor_lock
  local artifact_file
  artifact_file="$(perfetto_trace_processor_lock_value artifact_file)"
  printf '%s/.tools/%s\n' "$SCRIPT_DIR" "$artifact_file"
}

perfetto_validate_trace_processor() {
  local candidate="$1"
  perfetto_validate_trace_processor_lock
  [[ -n "$candidate" ]] || perfetto_die 'trace_processor_shell vacio'
  [[ ! -L "$candidate" ]] ||
    perfetto_die "trace_processor_shell no puede ser symlink: ${candidate}"
  [[ -f "$candidate" && -x "$candidate" ]] ||
    perfetto_die "trace_processor_shell no es regular/ejecutable: ${candidate}"

  local candidate_dir
  local canonical_candidate
  candidate_dir="$(cd -- "$(dirname -- "$candidate")" && pwd -P)"
  canonical_candidate="${candidate_dir}/$(basename -- "$candidate")"

  local expected_size
  local expected_sha256
  local release
  local release_commit
  local actual_size
  local actual_sha256
  local actual_version
  local expected_version
  expected_size="$(
    perfetto_trace_processor_lock_value artifact_size_bytes
  )"
  expected_sha256="$(perfetto_trace_processor_lock_value artifact_sha256)"
  release="$(perfetto_trace_processor_lock_value release)"
  release_commit="$(perfetto_trace_processor_lock_value release_commit)"
  actual_size="$(stat -c '%s' -- "$canonical_candidate")"
  actual_sha256="$(sha256sum "$canonical_candidate" | awk '{print $1}')"
  expected_version="Perfetto ${release}-${release_commit:0:9} (${release_commit})"

  [[ "$actual_size" == "$expected_size" ]] ||
    perfetto_die 'trace_processor_shell no coincide en tamano con el lock'
  [[ "$actual_sha256" == "$expected_sha256" ]] ||
    perfetto_die 'trace_processor_shell no coincide en SHA-256 con el lock'
  actual_version="$("$canonical_candidate" --version 2>&1)"
  actual_version="${actual_version%%$'\n'*}"
  [[ "$actual_version" == "$expected_version" ]] ||
    perfetto_die \
      "trace_processor_shell no coincide en version/commit: ${actual_version}"

  printf '%s\n' "$canonical_candidate"
}

perfetto_resolve_adb() {
  local candidate="${ADB_BIN:-adb}"
  if [[ "$candidate" == */* ]]; then
    [[ -x "$candidate" ]] || perfetto_die "ADB_BIN no es ejecutable: ${candidate}"
  else
    command -v -- "$candidate" >/dev/null 2>&1 ||
      perfetto_die "no se encontro adb en PATH: ${candidate}"
  fi
  printf '%s\n' "$candidate"
}

perfetto_source_is_allowed() {
  local candidate="$1"
  local allowed
  for allowed in "${PERFETTO_ALLOWED_SOURCES[@]}"; do
    [[ "$candidate" == "$allowed" ]] && return 0
  done
  return 1
}

perfetto_query_has_source() {
  local query_output="$1"
  local source="$2"
  local escaped="${source//./\\.}"
  # A pipe into grep -q is not safe under pipefail: grep closes early on this
  # very large --long report and printf then exits with SIGPIPE. A here-string
  # preserves the real grep result.
  # In --query --long, registered data-source rows begin with the source name.
  # Anchoring the match avoids mistaking a category/detail value for a
  # registered source.
  grep -Eq "^[[:space:]]*${escaped}([[:space:]]|$)" <<<"$query_output"
}

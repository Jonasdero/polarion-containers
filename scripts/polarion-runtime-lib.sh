#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REQUESTED_POLARION_RUNTIME="${POLARION_RUNTIME-}"
POLARION_RUNTIME="${POLARION_RUNTIME:-}"
POLARION_CONTAINER_NAME="${POLARION_CONTAINER_NAME:-polarion}"
POLARION_EXTENSION_NAME="${POLARION_EXTENSION_NAME:-custom}"
POLARION_IMAGE="${POLARION_IMAGE:-polarion:local}"
POLARION_HTTP_PORT="${POLARION_HTTP_PORT:-80}"
POLARION_DB_PORT="${POLARION_DB_PORT:-5433}"
POLARION_JDWP_PORT="${POLARION_JDWP_PORT:-5005}"
POLARION_BIND_HOST="${POLARION_BIND_HOST:-127.0.0.1}"
POLARION_JAVA_OPTS="${POLARION_JAVA_OPTS-}"
POLARION_JDWP_ENABLED="${POLARION_JDWP_ENABLED:-true}"
POLARION_PLATFORM="${POLARION_PLATFORM:-linux/amd64}"
POLARION_CONTAINER_CPUS="${POLARION_CONTAINER_CPUS:-8}"
POLARION_CONTAINER_MEMORY="${POLARION_CONTAINER_MEMORY-}"
POLARION_BUILDER_CPUS="${POLARION_BUILDER_CPUS:-8}"
POLARION_BUILDER_MEMORY="${POLARION_BUILDER_MEMORY-}"
POLARION_MAX_CONTAINER_MEMORY_MB="${POLARION_MAX_CONTAINER_MEMORY_MB-}"
POLARION_MAX_HEAP_MB="${POLARION_MAX_HEAP_MB-}"
POLARION_AUTO_ACTIVATE_TRIAL="${POLARION_AUTO_ACTIVATE_TRIAL:-true}"
POLARION_DATA_VOLUME="${POLARION_DATA_VOLUME:-polarion_repo}"
POLARION_EXTENSIONS_VOLUME="${POLARION_EXTENSIONS_VOLUME:-polarion_extensions}"
POLARION_WORKSPACE_VOLUME="${POLARION_WORKSPACE_VOLUME:-polarion_workspace}"
POLARION_DATA_DIR="${POLARION_DATA_DIR:-${REPO_ROOT}/data}"
POLARION_FILES_DIR="${POLARION_FILES_DIR:-${REPO_ROOT}/files}"
POLARION_DOCKERFILE="${POLARION_DOCKERFILE:-${REPO_ROOT}/Dockerfile}"
POLARION_START_TIMEOUT="${POLARION_START_TIMEOUT:-900}"
POLARION_START_POLL_INTERVAL="${POLARION_START_POLL_INTERVAL:-5}"
POLARION_WORKSPACE_INDEX_DIR="${POLARION_WORKSPACE_INDEX_DIR:-/opt/polarion/data/workspace/polarion-data}"
POLARION_WORKSPACE_METADATA_DIR="${POLARION_WORKSPACE_METADATA_DIR:-/opt/polarion/data/workspace/.metadata}"
POLARION_WORKSPACE_CONFIG_DIR="${POLARION_WORKSPACE_CONFIG_DIR:-/opt/polarion/data/workspace/.config}"

polarion_usage_error() {
	echo "Error: $*" >&2
	exit 1
}

polarion_memory_to_mb() {
	local value="${1:-}"
	local number=""
	local unit=""

	if [[ -z "${value}" ]]; then
		return 1
	fi

	if [[ "${value}" =~ ^([0-9]+)([gGmMkK])?$ ]]; then
		number="${BASH_REMATCH[1]}"
		unit="${BASH_REMATCH[2]:-m}"
	else
		return 1
	fi

	case "${unit}" in
		g|G)
			printf '%s\n' "$(( number * 1024 ))"
			;;
		m|M)
			printf '%s\n' "${number}"
			;;
		k|K)
			printf '%s\n' "$(( number / 1024 ))"
			;;
		*)
			return 1
			;;
	esac
}

polarion_format_mb() {
	local mb="$1"
	if (( mb % 1024 == 0 )); then
		printf '%sg\n' "$(( mb / 1024 ))"
	else
		printf '%sm\n' "${mb}"
	fi
}

polarion_cap_memory_limit() {
	local requested="$1"
	local parsed_mb=""

	parsed_mb="$(polarion_memory_to_mb "${requested}")" || {
		printf '%s\n' "${requested}"
		return 0
	}

	if (( parsed_mb > POLARION_MAX_CONTAINER_MEMORY_MB )); then
		echo "Capping requested memory ${requested} to $(polarion_format_mb "${POLARION_MAX_CONTAINER_MEMORY_MB}")" >&2
		parsed_mb="${POLARION_MAX_CONTAINER_MEMORY_MB}"
	fi

	polarion_format_mb "${parsed_mb}"
}

polarion_cap_java_heap_flag() {
	local opts="$1"
	local flag="$2"
	local regex="${flag}([0-9]+)([gGmMkK])"
	local whole=""
	local current_mb=""

	if [[ "${opts}" =~ ${regex} ]]; then
		whole="${BASH_REMATCH[0]}"
		current_mb="$(polarion_memory_to_mb "${BASH_REMATCH[1]}${BASH_REMATCH[2]}")" || current_mb=""
		if [[ -n "${current_mb}" ]] && (( current_mb > POLARION_MAX_HEAP_MB )); then
			echo "Capping ${flag} in JAVA_OPTS from ${whole} to ${flag}$(polarion_format_mb "${POLARION_MAX_HEAP_MB}")" >&2
			opts="${opts/${whole}/${flag}$(polarion_format_mb "${POLARION_MAX_HEAP_MB}")}"
		fi
	fi

	printf '%s\n' "${opts}"
}

polarion_normalize_resource_limits() {
	POLARION_CONTAINER_MEMORY="$(polarion_cap_memory_limit "${POLARION_CONTAINER_MEMORY}")"
	POLARION_BUILDER_MEMORY="$(polarion_cap_memory_limit "${POLARION_BUILDER_MEMORY}")"
	POLARION_JAVA_OPTS="$(polarion_cap_java_heap_flag "${POLARION_JAVA_OPTS}" "-Xmx")"
	POLARION_JAVA_OPTS="$(polarion_cap_java_heap_flag "${POLARION_JAVA_OPTS}" "-Xms")"
}

polarion_apply_runtime_defaults() {
	if polarion_is_apple_container_runtime; then
		# Apple container runtime hard-caps at 4 GB regardless of the -m flag.
		# Java RSS with -Xmx3g peaks at ~3.3 GB, leaving <700 MB for Node, Postgres,
		# Apache, and OS buffers — the OOM killer fires under any real load.
		# 2.5 GB heap keeps total RSS well within 4 GB.
		POLARION_JAVA_OPTS="${POLARION_JAVA_OPTS:--Xmx2560m -Xms2560m}"
		POLARION_CONTAINER_MEMORY="${POLARION_CONTAINER_MEMORY:-4g}"
		POLARION_BUILDER_MEMORY="${POLARION_BUILDER_MEMORY:-4g}"
		POLARION_MAX_CONTAINER_MEMORY_MB="${POLARION_MAX_CONTAINER_MEMORY_MB:-4096}"
		POLARION_MAX_HEAP_MB="${POLARION_MAX_HEAP_MB:-2560}"
	else
		POLARION_JAVA_OPTS="${POLARION_JAVA_OPTS:--Xmx3g -Xms3g}"
		POLARION_CONTAINER_MEMORY="${POLARION_CONTAINER_MEMORY:-4g}"
		POLARION_BUILDER_MEMORY="${POLARION_BUILDER_MEMORY:-4g}"
		POLARION_MAX_CONTAINER_MEMORY_MB="${POLARION_MAX_CONTAINER_MEMORY_MB:-4096}"
		POLARION_MAX_HEAP_MB="${POLARION_MAX_HEAP_MB:-3072}"
	fi
}

polarion_require_command() {
	command -v "$1" >/dev/null 2>&1 || polarion_usage_error "Required command not found: $1"
}

polarion_command_available() {
	command -v "$1" >/dev/null 2>&1
}

polarion_host_is_apple_silicon() {
	[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]
}

polarion_runtime_has_named_container() {
	local runtime="$1"

	case "${runtime}" in
		container)
			polarion_command_available container || return 1
			container inspect "${POLARION_CONTAINER_NAME}" >/dev/null 2>&1
			;;
		docker)
			polarion_command_available docker || return 1
			docker inspect "${POLARION_CONTAINER_NAME}" >/dev/null 2>&1
			;;
		*)
			return 1
			;;
	esac
}

polarion_probe_host() {
	case "${POLARION_BIND_HOST}" in
		""|0.0.0.0|::)
			printf '127.0.0.1\n'
			;;
		*)
			printf '%s\n' "${POLARION_BIND_HOST}"
			;;
	esac
}

polarion_base_url() {
	printf 'http://%s:%s/polarion/' "$(polarion_probe_host)" "${POLARION_HTTP_PORT}"
}

polarion_activation_entry_url() {
	printf 'http://%s:%s/polarion/activate/entry' "$(polarion_probe_host)" "${POLARION_HTTP_PORT}"
}

polarion_read_http_status_line() {
	local host="$1"
	local port="$2"
	local path="$3"
	local status_line=""

	exec 3<>"/dev/tcp/${host}/${port}" || return 1
	printf 'GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' "${path}" >&3
	IFS=$'\r' read -r status_line <&3 || true
	exec 3<&-
	exec 3>&-

	[ -n "${status_line}" ] || return 1
	printf '%s\n' "${status_line}"
}

polarion_http_status_accessible() {
	local status_line="$1"
	local status_code=""

	[ -n "${status_line}" ] || return 1
	status_code="${status_line#HTTP/* }"
	status_code="${status_code%% *}"

	case "${status_code}" in
		2??|3??|401|403)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

polarion_wait_for_http_access() {
	local host
	local url
	local deadline
	local last_status=""

	host="$(polarion_probe_host)"
	url="$(polarion_base_url)"
	deadline=$((SECONDS + POLARION_START_TIMEOUT))

	echo "Waiting for Polarion HTTP endpoint at ${url} ..."

	while (( SECONDS < deadline )); do
		last_status="$(polarion_read_http_status_line "${host}" "${POLARION_HTTP_PORT}" "/polarion/" 2>/dev/null || true)"
		if polarion_http_status_accessible "${last_status}"; then
			echo "Polarion is reachable at ${url} (${last_status})"
			return 0
		fi
		sleep "${POLARION_START_POLL_INTERVAL}"
	done

	if [ -n "${last_status}" ]; then
		echo "Polarion did not become reachable within ${POLARION_START_TIMEOUT}s. Last HTTP response: ${last_status}" >&2
	else
		echo "Polarion did not become reachable within ${POLARION_START_TIMEOUT}s. No HTTP response received from ${url}" >&2
	fi
	echo "Inspect logs with: POLARION_RUNTIME=${POLARION_RUNTIME} bash scripts/polarionctl.sh logs" >&2
	return 1
}

polarion_fetch_root_page() {
	curl --silent --show-error --location --max-time 30 "$(polarion_base_url)"
}

polarion_auto_activate_trial_if_needed() {
	local page=""
	local response=""
	local deadline=0

	if [[ "${POLARION_AUTO_ACTIVATE_TRIAL}" != "true" ]]; then
		return 0
	fi

	page="$(polarion_fetch_root_page 2>/dev/null || true)"
	if [[ "${page}" != *"<title>Polarion Activation</title>"* ]]; then
		return 0
	fi

	echo "Polarion is on the activation page. Starting local 30-day trial..."
	response="$(curl --silent --show-error --max-time 30 \
		-X POST "$(polarion_activation_entry_url)" \
		-H 'X-Requested-With: XMLHttpRequest' \
		-d '' || true)"

	if [[ "${response}" != *'"activated":true'* ]]; then
		echo "Trial activation failed: ${response:-no response}" >&2
		return 1
	fi

	deadline=$((SECONDS + 60))
	while (( SECONDS < deadline )); do
		page="$(polarion_fetch_root_page 2>/dev/null || true)"
		if [[ "${page}" != *"<title>Polarion Activation</title>"* ]]; then
			echo "Polarion trial activation completed."
			return 0
		fi
		sleep 2
	done

	echo "Trial activation did not leave the activation page within 60s." >&2
	return 1
}

polarion_select_runtime() {
	if [ -n "${REQUESTED_POLARION_RUNTIME}" ]; then
		case "${REQUESTED_POLARION_RUNTIME}" in
			docker|container)
				POLARION_RUNTIME="${REQUESTED_POLARION_RUNTIME}"
				return 0
				;;
			*)
				polarion_usage_error "Unsupported POLARION_RUNTIME '${REQUESTED_POLARION_RUNTIME}'. Use 'docker' or 'container'."
				;;
		esac
	fi

	if polarion_runtime_has_named_container container; then
		POLARION_RUNTIME="container"
		return 0
	fi

	if polarion_runtime_has_named_container docker; then
		POLARION_RUNTIME="docker"
		return 0
	fi

	if polarion_command_available docker; then
		POLARION_RUNTIME="docker"
	elif polarion_command_available container; then
		POLARION_RUNTIME="container"
	else
		POLARION_RUNTIME="docker"
	fi
}

polarion_require_selected_runtime_command() {
	if polarion_is_apple_container_runtime; then
		polarion_require_command container
	else
		polarion_require_command docker
	fi
}

polarion_is_apple_container_runtime() {
	[[ "${POLARION_RUNTIME}" == "container" ]]
}

polarion_apply_runtime_defaults
polarion_normalize_resource_limits

polarion_platform_needs_rosetta() {
	[[ "${POLARION_PLATFORM}" == *"amd64"* ]]
}

polarion_runtime_exec() {
	local container_name="$1"
	local command_string="$2"

	polarion_require_selected_runtime_command

	if polarion_is_apple_container_runtime; then
		container exec --interactive "${container_name}" sh -c "${command_string}"
	else
		docker exec -i "${container_name}" sh -c "${command_string}"
	fi
}

polarion_reindex_workspace() {
	polarion_require_selected_runtime_command

	if ! polarion_runtime_has_named_container "${POLARION_RUNTIME}"; then
		polarion_usage_error "No running Polarion container named '${POLARION_CONTAINER_NAME}' found."
	fi

	echo "Stopping Polarion service before workspace reindex..."
	polarion_runtime_exec "${POLARION_CONTAINER_NAME}" 'service polarion stop'

	echo "Removing workspace index directories..."
	polarion_runtime_exec "${POLARION_CONTAINER_NAME}" \
		"rm -rf \"${POLARION_WORKSPACE_INDEX_DIR}\" \"${POLARION_WORKSPACE_METADATA_DIR}\" \"${POLARION_WORKSPACE_CONFIG_DIR}\""

	echo "Starting Polarion service after workspace reindex..."
	polarion_runtime_exec "${POLARION_CONTAINER_NAME}" 'service polarion start'

	polarion_wait_for_http_access
}

polarion_runtime_copy_file() {
	local container_name="$1"
	local source_path="$2"
	local target_path="$3"

	polarion_require_selected_runtime_command

	if polarion_is_apple_container_runtime; then
		container exec --interactive "${container_name}" sh -c "cat > \"${target_path}\"" < "${source_path}"
	else
		docker cp "${source_path}" "${container_name}:${target_path}"
	fi
}

polarion_sync_repo_license() {
	local source_path=""
	local avasis_source_path=""
	local first_line=""
	local non_xml_license_path=""

	if [ -d "${POLARION_DATA_DIR}" ]; then
		while IFS= read -r candidate; do
			avasis_source_path="${candidate}"
			break
		done < <(
			find "${POLARION_DATA_DIR}" -maxdepth 1 -type f \
				\( -iname 'avasis.licence' -o -iname 'avasis.license' -o -iname '*avasis*.lic*' \) \
				| sort
		)
	fi

	if [ -n "${avasis_source_path}" ]; then
		echo "Syncing avasis license ${avasis_source_path##*/} into Polarion..."
		polarion_runtime_copy_file "${POLARION_CONTAINER_NAME}" "${avasis_source_path}" "/opt/polarion/polarion/license/avasis.licence"
		polarion_runtime_exec "${POLARION_CONTAINER_NAME}" \
			'chown polarion:www-data /opt/polarion/polarion/license/avasis.licence && chmod 0644 /opt/polarion/polarion/license/avasis.licence'
	else
		echo "No avasis license file found in ${POLARION_DATA_DIR}; keeping current /opt/polarion/polarion/license/avasis.licence."
	fi

	if [ ! -d "${POLARION_FILES_DIR}" ]; then
		return 0
	fi

	while IFS= read -r candidate; do
		first_line="$(LC_ALL=C sed -n '1{s/^\xEF\xBB\xBF//;p;q;}' "${candidate}" 2>/dev/null || true)"
		first_line="${first_line#"${first_line%%[![:space:]]*}"}"

		case "${first_line}" in
			'<?xml '*|'<polarionLicenseFile>'*)
				source_path="${candidate}"
				break
				;;
			*)
				if [ -z "${non_xml_license_path}" ]; then
					non_xml_license_path="${candidate}"
				fi
				;;
		esac
	done < <(
		find "${POLARION_FILES_DIR}" -maxdepth 1 -type f \
			\( -iname '*avasis*.lic*' -o -iname '*.lic' -o -iname '*.licence' -o -iname '*.license' \) \
			| sort
	)

	if [ -z "${source_path}" ]; then
		if [ -n "${non_xml_license_path}" ]; then
			echo "Detected non-XML license artifact ${non_xml_license_path##*/}; leaving image/default polarion.lic in place."
			echo "Use this artifact as an activation key or extension license, not as /opt/polarion/polarion/license/polarion.lic."
			return 0
		fi

		echo "No repo license file found in ${POLARION_FILES_DIR}; keeping image default license."
		return 0
	fi

	echo "Syncing repo XML license ${source_path##*/} into Polarion..."
	polarion_runtime_copy_file "${POLARION_CONTAINER_NAME}" "${source_path}" "/opt/polarion/polarion/license/polarion.lic"
	polarion_runtime_exec "${POLARION_CONTAINER_NAME}" \
		'chown polarion:www-data /opt/polarion/polarion/license/polarion.lic && chmod 0644 /opt/polarion/polarion/license/polarion.lic'
}

polarion_ensure_volume() {
	local volume_name="$1"

	polarion_require_selected_runtime_command

	if polarion_is_apple_container_runtime; then
		if ! container volume inspect "${volume_name}" >/dev/null 2>&1; then
			container volume create "${volume_name}" >/dev/null
		fi
	else
		if ! docker volume inspect "${volume_name}" >/dev/null 2>&1; then
			docker volume create "${volume_name}" >/dev/null
		fi
	fi
}

polarion_remove_container() {
	polarion_require_selected_runtime_command

	if polarion_is_apple_container_runtime; then
		container delete --force "${POLARION_CONTAINER_NAME}" >/dev/null 2>&1 || true
	else
		docker rm -f "${POLARION_CONTAINER_NAME}" >/dev/null 2>&1 || true
	fi
}

polarion_ensure_container_system() {
	if polarion_is_apple_container_runtime; then
		polarion_require_command container
		container system status >/dev/null 2>&1 || container system start
	fi
}

polarion_ensure_builder() {
	if ! polarion_is_apple_container_runtime; then
		return 0
	fi

	polarion_ensure_container_system
	if polarion_platform_needs_rosetta; then
		container system property set build.rosetta true >/dev/null
	fi

	if ! container builder status >/dev/null 2>&1; then
		container builder start --cpus "${POLARION_BUILDER_CPUS}" --memory "${POLARION_BUILDER_MEMORY}"
	fi
}

polarion_stop_builder() {
	if ! polarion_is_apple_container_runtime; then
		return 0
	fi

	polarion_require_command container
	container builder stop >/dev/null 2>&1 || true
}

polarion_select_runtime

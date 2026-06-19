#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./polarion-runtime-lib.sh
source "${SCRIPT_DIR}/polarion-runtime-lib.sh"

container_script="$(mktemp)"
trap 'rm -f "${container_script}"' EXIT

cat >"${container_script}" <<'EOF'
#!/bin/sh
set -eu

POLARION_PROPERTIES="/opt/polarion/etc/polarion.properties"
SVN_DATA_DIR="/opt/polarion/data/svn"
SVN_RUNTIME_DIR="/srv/polarion/svn"
SVN_HTTP_AUTH_FILE="/etc/apache2/polarion-svn-http.passwd"
SVN_INTERNAL_PASSWD_FILE="$SVN_DATA_DIR/passwd"
SVN_EXTERNAL_PASSWD_FILE="$SVN_DATA_DIR/passwd_credentials"

read_polarion_property() {
	key="$1"
	default_value="$2"
	value=""

	if [ -f "$POLARION_PROPERTIES" ]; then
		value="$(sed -n "s/^${key}=//p" "$POLARION_PROPERTIES" | tail -n 1)"
	fi

	if [ -n "$value" ]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$default_value"
	fi
}

normalize_svn_passwd_file() {
	passwd_file="$1"
	repo_user="$2"
	repo_password="$3"
	admin_user="$4"
	admin_password="$5"
	tmp_file="$(mktemp)"

	if [ -f "$passwd_file" ]; then
		awk -F: -v repo_user="$repo_user" -v admin_user="$admin_user" '
			$1 != repo_user && $1 != admin_user { print }
		' "$passwd_file" >"$tmp_file"
	else
		: >"$tmp_file"
	fi

	htpasswd -bcm "$tmp_file" "$repo_user" "$repo_password" >/dev/null
	htpasswd -bm "$tmp_file" "$admin_user" "$admin_password" >/dev/null
	install -o polarion -g www-data -m 0664 "$tmp_file" "$passwd_file"
	rm -f "$tmp_file"
}

SVN_REPO_USER="$(read_polarion_property "login" "polarion")"
SVN_REPO_PASSWORD="$(read_polarion_property "password" "aurora")"
SVN_ADMIN_USER="$(read_polarion_property "adminUser" "admin")"
SVN_ADMIN_PASSWORD="$(read_polarion_property "adminPasswd" "admin")"

normalize_svn_passwd_file \
	"$SVN_INTERNAL_PASSWD_FILE" \
	"$SVN_REPO_USER" \
	"$SVN_REPO_PASSWORD" \
	"$SVN_ADMIN_USER" \
	"$SVN_ADMIN_PASSWORD"

normalize_svn_passwd_file \
	"$SVN_EXTERNAL_PASSWD_FILE" \
	"$SVN_REPO_USER" \
	"$SVN_REPO_PASSWORD" \
	"$SVN_ADMIN_USER" \
	"$SVN_ADMIN_PASSWORD"

if [ -d "$SVN_RUNTIME_DIR" ]; then
	if [ ! "$SVN_RUNTIME_DIR/passwd" -ef "$SVN_INTERNAL_PASSWD_FILE" ]; then
		install -o polarion -g www-data -m 0664 "$SVN_INTERNAL_PASSWD_FILE" "$SVN_RUNTIME_DIR/passwd"
	fi
fi

if [ -d "/etc/apache2" ]; then
	install -o root -g www-data -m 0644 "$SVN_EXTERNAL_PASSWD_FILE" "$SVN_HTTP_AUTH_FILE"
	perl -0pi -e 's#(<Location /repo>.*?AuthUserFile )".*?"#${1}"/srv/polarion/svn/passwd"#sg' \
		/etc/apache2/conf-available/polarionSVN.conf \
		/etc/apache2/conf-enabled/polarionSVN.conf
	perl -0pi -e 's#(<Location /installrepo>.*?AuthUserFile )".*?"#${1}"/srv/polarion/svn/passwd"#sg' \
		/etc/apache2/conf-available/polarionSVN.conf \
		/etc/apache2/conf-enabled/polarionSVN.conf
	perl -0pi -e 's#(<Location /repo-local>.*?AuthUserFile )".*?"#${1}"/etc/apache2/polarion-svn-http.passwd"#sg' \
		/etc/apache2/conf-available/polarionSVN.conf \
		/etc/apache2/conf-enabled/polarionSVN.conf
	perl -0pi -e 's#[ \t]*<RequireAny>[ \t]*\r?\n[ \t]*Require local[ \t]*\r?\n[ \t]*Require valid-user[ \t]*\r?\n[ \t]*</RequireAny>[ \t]*#Require valid-user#g' \
		/etc/apache2/conf-available/polarionSVN.conf \
		/etc/apache2/conf-enabled/polarionSVN.conf
fi

chown -R polarion:www-data "$SVN_DATA_DIR"
find "$SVN_DATA_DIR" -type d -exec chmod 2775 {} +
find "$SVN_DATA_DIR" -type f -exec chmod 0664 {} +

if [ -d "$SVN_RUNTIME_DIR/repo" ]; then
	chown -R polarion:www-data "$SVN_RUNTIME_DIR/repo"
	find "$SVN_RUNTIME_DIR/repo" -type d -exec chmod 2775 {} +
	find "$SVN_RUNTIME_DIR/repo" -type f -exec chmod 0664 {} +
fi

htpasswd -vb "$SVN_EXTERNAL_PASSWD_FILE" "$SVN_ADMIN_USER" "$SVN_ADMIN_PASSWORD" >/dev/null
htpasswd -vb "$SVN_EXTERNAL_PASSWD_FILE" "$SVN_REPO_USER" "$SVN_REPO_PASSWORD" >/dev/null
htpasswd -vb "$SVN_INTERNAL_PASSWD_FILE" "$SVN_ADMIN_USER" "$SVN_ADMIN_PASSWORD" >/dev/null
htpasswd -vb "$SVN_INTERNAL_PASSWD_FILE" "$SVN_REPO_USER" "$SVN_REPO_PASSWORD" >/dev/null
htpasswd -vb "$SVN_HTTP_AUTH_FILE" "$SVN_ADMIN_USER" "$SVN_ADMIN_PASSWORD" >/dev/null
htpasswd -vb "$SVN_HTTP_AUTH_FILE" "$SVN_REPO_USER" "$SVN_REPO_PASSWORD" >/dev/null

if command -v service >/dev/null 2>&1; then
	service apache2 reload >/dev/null 2>&1 || true
fi
EOF

polarion_runtime_copy_file "${POLARION_CONTAINER_NAME}" "${container_script}" "/tmp/repair-svn-auth.sh"
polarion_runtime_exec "${POLARION_CONTAINER_NAME}" "chmod 0755 /tmp/repair-svn-auth.sh && /tmp/repair-svn-auth.sh && rm -f /tmp/repair-svn-auth.sh"

echo "SVN auth normalized for container ${POLARION_CONTAINER_NAME}."

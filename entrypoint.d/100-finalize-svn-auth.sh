#!/bin/bash

SVN_DATA_DIR="/opt/polarion/data/svn"
SVN_HTTP_AUTH_FILE="/etc/apache2/polarion-svn-http.passwd"
SVN_INTERNAL_PASSWD_FILE="$SVN_DATA_DIR/passwd"
SVN_EXTERNAL_PASSWD_FILE="$SVN_DATA_DIR/passwd_credentials"
POLARION_PROPERTIES="/opt/polarion/etc/polarion.properties"

read_polarion_property() {
	local key="$1"
	local default_value="$2"
	local value=""

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
	local passwd_file="$1"
	local repo_user="$2"
	local repo_password="$3"
	local admin_user="$4"
	local admin_password="$5"
	local tmp_file

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

# Polarion startup can rewrite the SVN htpasswd files after the early bootstrap step.
# Normalize both the internal runtime file and the external Apache copy once more
# after the service start so Polarion UI access and direct HTTP access stay aligned.
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

if [ -d "/srv/polarion/svn" ] && [ ! "/srv/polarion/svn/passwd" -ef "$SVN_INTERNAL_PASSWD_FILE" ]; then
	install -o polarion -g www-data -m 0664 "$SVN_INTERNAL_PASSWD_FILE" "/srv/polarion/svn/passwd"
fi

if [ -d "/etc/apache2" ]; then
	install -o root -g www-data -m 0644 "$SVN_EXTERNAL_PASSWD_FILE" "$SVN_HTTP_AUTH_FILE"
fi

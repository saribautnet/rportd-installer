#
# Update of the RPort Server
#
if [ -e /usr/local/bin/rportd ]; then
  CURRENT_VERSION=$(/usr/local/bin/rportd --version | awk '{print $2}')
else
  throw_fatal "No rportd binary found in /usr/local/bin/rportd"
fi

cd /tmp
ARCH=$(uname -m)
URL="https://download.rport.io/rportd/${RELEASE}/?arch=Linux_${ARCH}&gt=${CURRENT_VERSION}"
curl -Ls "${URL}" -o rportd.tar.gz
test -e rportd && rm -f rportd
if tar xzf rportd.tar.gz rportd 2>/dev/null; then
  TARGET_VERSION=$(./rportd --version | awk '{print $2}')
  rm rportd.tar.gz
else
  rm rportd.tar.gz
  throw_info "Nothing to do. RPortd is on the latest version ${CURRENT_VERSION}."
  exit 0
fi

systemctl stop rportd

if [ "$DO_BACKUP" -eq 1 ]; then
  # Create a backup
  FOLDERS=(/usr/local/bin/rportd /var/lib/rport /var/log/rport /etc/rport)
  throw_info "Creating a backup of your RPort data. This can take a while."
  throw_debug "${FOLDERS[*]} will be backed up."
  BACKUP_FILE=/var/backups/rportd-$(date +%Y%m%d-%H%M%S).tar.gz
  throw_info "Be patient! The backup might take minutes or half an hour depending on your database sizes."
  if is_available pv; then
    EST_SIZE=$(du -sb /var/lib/rport | awk '{print $1}')
    tar cf - "${FOLDERS[@]}" | pv -s "$EST_SIZE" | gzip >"$BACKUP_FILE"
  else
    tar cvzf "$BACKUP_FILE" "${FOLDERS[@]}"
  fi
  throw_info "A backup has been created in $BACKUP_FILE"
else
  throw_info "Backup skipped"
fi

# Update server
mv rportd /usr/local/bin/rportd

# After each update you need to allow binding to privileged ports
setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/rportd
throw_info "/usr/local/bin/rportd updated to version $TARGET_VERSION"

# If you come from a old versions create columns if missing.
# Ignore the errors if the columns exist.
throw_info "Performing database migrations where needed."
if [ -e "${AUTH_DB}" ]; then
  sqlite3 "${AUTH_DB}" \
    'ALTER TABLE "users" ADD column "token" TEXT(36) DEFAULT NULL' 2>/dev/null || true
  sqlite3 "${AUTH_DB}" \
    'ALTER TABLE "users" ADD column "two_fa_send_to" TEXT(150) DEFAULT NULL' 2>/dev/null || true
  sqlite3 "${AUTH_DB}" \
    'ALTER TABLE "users" ADD column "totp_secret" TEXT DEFAULT ""' 2>/dev/null || true
  sqlite3 "${AUTH_DB}" \
    'ALTER TABLE "users" ADD column "password_expired" BOOLEAN NOT NULL CHECK (password_expired IN (0, 1)) DEFAULT 0' 2>/dev/null || true
fi
# Activate the new reverse proxy feature
CONFIG_FILE=/etc/rport/rportd.conf

activate_proxy() {
  if grep -q tunnel_proxy_cert_file $CONFIG_FILE; then
    throw_info "Reverse Proxy already activated"
    return 0
  fi
  CERT_FILE=$(grep "^\W*cert_file =" $CONFIG_FILE | sed -e "s/cert_file = \"\(.*\)\"/\1/g" | tr -d " ")
  KEY_FILE=$(grep "^\W*key_file =" $CONFIG_FILE | sed -e "s/key_file = \"\(.*\)\"/\1/g" | tr -d " ")

  if [ -e "$CERT_FILE" ] && [ -e "$KEY_FILE" ]; then
    throw_debug "Key and certificate found."
    sed -i "/^\[server\]/a \ \ tunnel_proxy_cert_file = \"$CERT_FILE\"" $CONFIG_FILE
    sed -i "/^\[server\]/a \ \ tunnel_proxy_key_file = \"$KEY_FILE\"" $CONFIG_FILE
    throw_info "Reverse proxy activated"
  fi
}
activate_proxy

# Enable monitoring
activate_monitoring() {
  if grep -q "\[monitoring\]" $CONFIG_FILE; then
    throw_info "Monitoring is already enabled."
    return 0
  fi
  echo '
[monitoring]
  ## The rport server stores monitoring data of the clients for N days.
  ## https://oss.rport.io/docs/no17-monitoring.html
  ## Older data is purged automatically.
  ## Default: 30 days
  data_storage_days = 7
  ' >>$CONFIG_FILE
  throw_info "Monitoring enabled."
}
activate_monitoring

activate_plus() {
  if grep -q "\[plus-plugin\]" $CONFIG_FILE; then
    throw_info "Plus plugin already present."
    return 0
  fi
  cat <<EOF >>$CONFIG_FILE
[plus-plugin]
  ## Rport Plus is a paid for binary extension to Rport. Learn more at https://plus.rport.io/
  # plugin_path = "/usr/local/lib/rport/rport-plus.so"

[plus-oauth]
  ## The Rport Plus OAuth capability support SSO/OAuth based user sign-in via a number of OAuth identity providers.
  ## -------------------------------------------------------------------------- ##
  ## Learn more at https://plus.rport.io/auth/oauth-introduction/
  ## -------------------------------------------------------------------------- ##

  ## provider - Required. Currently supported "github", "microsoft" or "google".
  # provider = "github"

  ## authorize_url - OAuth provider base url used for handling the user's authorization.
  # authorize_url = "https://github.com/login/oauth/authorize"

  ## redirect_uri - Required. URL where the OAuth provider will redirect  after completing the user’s authorization.
  # redirect_uri = "https://<FQDN-OF-RPORT>/oauth/callback"

  ## token_url - Required. OAuth provider base url where rportd will get an OAuth
  ## access token for looking up the user and organization/group info.
  # token_url = "https://github.com/login/oauth/access_token"

  ## client_id - identifier assigned to the Rport 'app' during the OAuth provider setup.
  # client_id = "<your client id>"

  ## client_secret - a secret provided by the OAuth provider to be used when exchanging an authorization code for
  ## OAuth provider tokens. Keep private and DO NOT included in any VCS, unencrypted backups, etc.
  # client_secret = "<your client secret>"

  ## device_client_id - google device style flow only
  ## identifier assigned to the Rport 'app' configured as part of the google device flow setup.
  # device_client_id = "<your google device client id>"

  ## device_authorize_url - Required. All the OAuth providers use a different url from the authorize_url for the
  ## device flow.  - if using the device style flow.
  # device_authorize_url = "https://github.com/login/device/code"

  ## device_client_secret - google device style flow only
  ## Keep private and DO NOT included in any VCS, unencrypted backups, etc.
  # device_client_secret = "<your google device client secret>"

  ## required_organization - GitHub only. GitHub organization whose users have permission to access the Rport server.
  # required_organization = ""

  ## required_group_id - Microsoft and Google only. Group id whose members have permission to access the RPort server.
  # required_group_id = ""

  ## permitted_user_list - Allow only users configured via the existing Rport 'api auth' mechanism.
  # permitted_user_list = true

  ## permitted_user_match - provides further control of the permitted users via a regex value.
  # permitted_user_match = ""
EOF
  throw_info "Plus plugin inserted but NOT activated. https://kb.rport.io/digging-deeper/rport-plus"
}
activate_plus

## Migrate renamed settings
if grep -q keep_lost_clients $CONFIG_FILE; then
  sed -i "s/keep_lost_clients/keep_disconnected_clients/g" $CONFIG_FILE
  throw_info "Migrated config 'keep_lost_clients' to 'keep_disconnected_clients'."
fi

update_2fa() {
  ## Update 2FA script if needed
  if grep -q "\-F remote_address=" /usr/local/bin/2fa-sender.sh; then
    true
  else
    SERVER_URL=$(grep "\-F url=" /usr/local/bin/2fa-sender.sh | grep -o "\".*\"" | tr -d '"')
    mv /usr/local/bin/2fa-sender.sh /tmp/2fa-sender.sh
    throw_info "/usr/local/bin/2fa-sender.sh backed to /tmp/2fa-sender.sh"
    create_2fa_script
    sed -i "s|_URL_|${SERVER_URL}|g" /usr/local/bin/2fa-sender.sh
    throw_info "/usr/local/bin/2fa-sender.sh updated"
  fi
}
## Update 2FA script if needed, if present
[ -e /usr/local/bin/2fa-sender.sh ] && update_2fa

activate_auth_group_details() {
  if grep -q auth_group_details_table $CONFIG_FILE; then
    throw_info "Auth group details already enabled"
    return 0
  fi
  sed -i "/\ \ auth_group_table/a \ \ auth_group_details_table = \"group_details\"" $CONFIG_FILE
  if [ ! -e "${AUTH_DB}" ]; then
    throw_debug "Auth DB ${AUTH_DB} not found. Maybe not managed by installer."
    return 0
  fi
  if sqlite3 "${AUTH_DB}" '.tables' | grep group_details; then
    throw_debug "Table group_details already present."
    return 0
  fi
  sqlite3 "${AUTH_DB}" <<EOF
CREATE TABLE "group_details" (name TEXT, permissions TEXT);
CREATE UNIQUE INDEX "main"."group_details_name" ON "group_details" ("name" ASC);
CREATE TABLE "group_details" (
    "name" TEXT(150) NOT NULL,
    "permissions" TEXT DEFAULT "{}"
);
CREATE UNIQUE INDEX "main"."name" ON "group_details" (
    "name" ASC
);
EOF
}
activate_auth_group_details

# Update the frontend
cd /var/lib/rport/docroot/
rm -rf ./*
curl -Ls https://downloads.rport.io/frontend/${RELEASE}/latest.php -o rport-frontend.zip
unzip -o -qq rport-frontend.zip && rm -f rport-frontend.zip
chown -R rport:rport /var/lib/rport/docroot/
FRONTEND_VERSION=$(sed s/rport-frontend-//g </var/lib/rport/docroot/version.txt)
throw_info "Frontend updated to ${FRONTEND_VERSION}"
if [ "$(version_to_int "$TARGET_VERSION")" -gt 5019 ]; then
  # Install guacamole proxy
  sed -i "/^\[logging\]/i \ \ #guacd_address = \"127.0.0.1:8442\"\n" $CONFIG_FILE
  install_guacd && activate_guacd
  # Install NoVNC JS
  if [ -e /var/lib/rport ]; then
    install_novnc
    activate_novnc
  fi
fi
# Start the server
systemctl start rportd
throw_info "You are now using RPort Server $TARGET_VERSION (Frontend ${FRONTEND_VERSION})"

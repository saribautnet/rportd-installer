# Install the RPort Server
ARCH=$(uname -m)
if [ -z "$USE_VERSION" ];then
  # Use latest version
  DOWNLOAD_URL="https://download.rport.io/rportd/${RELEASE}/latest.php?arch=${ARCH}"
else
  # Use a specific version
  DOWNLOAD_URL="https://github.com/cloudradar-monitoring/rport/releases/download/${USE_VERSION}/rportd_${USE_VERSION}_Linux_$(uname -m).tar.gz"
  if curl -i "$DOWNLOAD_URL" 2>&1 |grep -q "HTTP.*302";then
    true
  else
    throw_fatal "No download found for version ${USE_VERSION}"
  fi
fi
throw_debug "Downloading ${DOWNLOAD_URL}"
curl -LSs "${DOWNLOAD_URL}" -o rportd.tar.gz
tar vxzf rportd.tar.gz -C /usr/local/bin/ rportd
id rport >/dev/null 2>&1||useradd -d /var/lib/rport -m -U -r -s /bin/false rport
test -e /etc/rport||mkdir /etc/rport/
test -e /var/log/rport||mkdir /var/log/rport/
chown rport /var/log/rport/
tar vxzf rportd.tar.gz -C /etc/rport/ rportd.example.conf
cp /etc/rport/rportd.example.conf /etc/rport/rportd.conf

# Create a unique key for your instance
KEY_SEED=$(openssl rand -hex 18)
sed -i "s/key_seed = .*/key_seed =\"${KEY_SEED}\"/g" /etc/rport/rportd.conf

# Create a systemd service
/usr/local/bin/rportd --service install --service-user rport --config /etc/rport/rportd.conf||true
SYSTEMD_SERVICE="/etc/systemd/system/rportd.service"
if [ -e "$SYSTEMD_SERVICE" ];then
  throw_debug "Service file ${SYSTEMD_SERVICE} created"
else
  throw_fatal "Failed to create systemd service file ${SYSTEMD_SERVICE}"
fi
sed -i '/^\[Service\]/a LimitNPROC=512' "$SYSTEMD_SERVICE"
systemctl daemon-reload
#systemctl start rportd
systemctl enable rportd
if /usr/local/bin/rportd --version;then
  true
else
  throw_fatal "Unable to start the rport server. Check /var/log/rport/rportd.log"
fi
rm rportd.tar.gz
echo "------------------------------------------------------------------------------"
throw_info "The RPort server has been installed from the latest ${RELEASE} release. "
echo ""

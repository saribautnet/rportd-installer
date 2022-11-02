enable_email_2fa() {
  create_2fa_script
  sed -i "s|_URL_|https://${FQDN}:${API_PORT}|g" /usr/local/bin/2fa-sender.sh
  sed -i "s|_URL_|https://${FQDN}:${API_PORT}|g" /usr/local/bin/2fa-sender.sh
  sed -i "s|#two_fa_token_delivery.*|two_fa_token_delivery = \"/usr/local/bin/2fa-sender.sh\"|g" /etc/rport/rportd.conf
  sed -i "s|#two_fa_send_to_type.*|two_fa_send_to_type = \"email\"|g" /etc/rport/rportd.conf
  TWO_FA_MSG="After the log in, check the inbox of ${EMAIL} to get the two-factor token."
  systemctl restart rportd
  throw_info "${TWO_FA}-based two factor authentication installed."
}

enable_totp_2fa() {
  sed -i "s|#totp_enabled.*|totp_enabled = true|g" /etc/rport/rportd.conf
  sed -i "s|#totp_login_session_ttl|totp_login_session_ttl|g" /etc/rport/rportd.conf
  TWO_FA_MSG="After the log in, you must set up your TOTP authenticator app."
  systemctl restart rportd
  throw_info "${TWO_FA}-based two factor authentication installed."
}

if [ "$TWO_FA" == 'none' ]; then
  throw_info "Two factor authentication NOT installed."
elif [ "$TWO_FA" == 'totp' ]; then
    enable_totp_2fa
elif nc -v -w 1 -z free-2fa-sender.rport.io 443 2>/dev/null;then
  throw_debug "Connection to free-2fa-sender.rport.io port 443 succeeded."
  enable_email_2fa
else
  throw_info "Outgoing https connections seem to be blocked."
  throw_waring "Two factor authentication NOT installed."
fi
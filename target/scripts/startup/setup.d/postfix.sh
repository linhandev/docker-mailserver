#!/bin/bash

function _setup_postfix_sizelimits
{
  _log 'trace' "Configuring Postfix message size limit to '${POSTFIX_MESSAGE_SIZE_LIMIT}'"
  postconf "message_size_limit = ${POSTFIX_MESSAGE_SIZE_LIMIT}"

  _log 'trace' "Configuring Postfix mailbox size limit to '${POSTFIX_MAILBOX_SIZE_LIMIT}'"
  postconf "mailbox_size_limit = ${POSTFIX_MAILBOX_SIZE_LIMIT}"

  _log 'trace' "Configuring Postfix virtual mailbox size limit to '${POSTFIX_MAILBOX_SIZE_LIMIT}'"
  postconf "virtual_mailbox_limit = ${POSTFIX_MAILBOX_SIZE_LIMIT}"
}

function _setup_postfix_access_control
{
  _log 'trace' 'Configuring user access'

  if [[ -f /tmp/docker-mailserver/postfix-send-access.cf ]]
  then
    sed -i 's|smtpd_sender_restrictions =|smtpd_sender_restrictions = check_sender_access texthash:/tmp/docker-mailserver/postfix-send-access.cf,|' /etc/postfix/main.cf
  fi

  if [[ -f /tmp/docker-mailserver/postfix-receive-access.cf ]]
  then
    sed -i 's|smtpd_recipient_restrictions =|smtpd_recipient_restrictions = check_recipient_access texthash:/tmp/docker-mailserver/postfix-receive-access.cf,|' /etc/postfix/main.cf
  fi
}

function _setup_postfix_sasl
{
  if [[ ${ENABLE_SASLAUTHD} -eq 1 ]] && [[ ! -f /etc/postfix/sasl/smtpd.conf ]]
  then
    cat >/etc/postfix/sasl/smtpd.conf << EOF
pwcheck_method: saslauthd
mech_list: plain login
EOF
  fi

  if [[ ${ENABLE_SASLAUTHD} -eq 0 ]] && [[ ${SMTP_ONLY} -eq 1 ]]
  then
    sed -i -E \
      's|^smtpd_sasl_auth_enable =.*|smtpd_sasl_auth_enable = no|g' \
      /etc/postfix/main.cf
    sed -i -E \
      's|^  -o smtpd_sasl_auth_enable=.*|  -o smtpd_sasl_auth_enable=no|g' \
      /etc/postfix/master.cf
  fi
}

function _setup_postfix_aliases
{
  _log 'debug' 'Setting up Postfix aliases'
  _create_aliases
}

function _setup_postfix_vhost
{
  _log 'debug' 'Setting up Postfix vhost'
  _create_postfix_vhost
}

function _setup_postfix_inet_protocols
{
  [[ ${POSTFIX_INET_PROTOCOLS} == 'all' ]] && return 0

  _log 'trace' 'Setting up POSTFIX_INET_PROTOCOLS option'
  postconf "inet_protocols = ${POSTFIX_INET_PROTOCOLS}"
}

function _setup_postfix_virtual_transport
{
  [[ -z ${POSTFIX_DAGENT} ]] && return 0

  _log 'trace' "Changing Postfix virtual transport to '${POSTFIX_DAGENT}'"
  # Default value in main.cf should be 'lmtp:unix:/var/run/dovecot/lmtp'
  postconf "virtual_transport = ${POSTFIX_DAGENT}"
}

function _setup_postfix_override_configuration
{
  _log 'debug' 'Overriding / adjusting Postfix configuration with user-supplied values'

  if [[ -f /tmp/docker-mailserver/postfix-main.cf ]]
  then
    cat /tmp/docker-mailserver/postfix-main.cf >>/etc/postfix/main.cf
    _adjust_mtime_for_postfix_maincf

    # do not directly output to 'main.cf' as this causes a read-write-conflict
    postconf -n >/tmp/postfix-main-new.cf 2>/dev/null

    mv /tmp/postfix-main-new.cf /etc/postfix/main.cf
    _adjust_mtime_for_postfix_maincf
    _log 'trace' "Adjusted '/etc/postfix/main.cf' according to '/tmp/docker-mailserver/postfix-main.cf'"
  else
    _log 'trace' "No extra Postfix settings loaded because optional '/tmp/docker-mailserver/postfix-main.cf' was not provided"
  fi

  if [[ -f /tmp/docker-mailserver/postfix-master.cf ]]
  then
    while read -r LINE
    do
      if [[ ${LINE} =~ ^[0-9a-z] ]]
      then
        postconf -P "${LINE}"
      fi
    done < /tmp/docker-mailserver/postfix-master.cf
    _log 'trace' "Adjusted '/etc/postfix/master.cf' according to '/tmp/docker-mailserver/postfix-master.cf'"
  else
    _log 'trace' "No extra Postfix settings loaded because optional '/tmp/docker-mailserver/postfix-master.cf' was not provided"
  fi
}

function _setup_postfix_relay_hosts
{
  _setup_relayhost
}

function _setup_postfix_dhparam
{
  _setup_dhparam 'Postfix' '/etc/postfix/dhparams.pem'
}

function _setup_dnsbl_disable
{
  _log 'debug' 'Disabling postscreen DNS block lists'
  postconf 'postscreen_dnsbl_action = ignore'
  postconf 'postscreen_dnsbl_sites = '
}

function _setup_postfix_smtputf8
{
  _log 'trace' "Disabling Postfix's smtputf8 support"
  postconf 'smtputf8_enable = no'
}

function _setup_SRS
{
  _log 'debug' 'Setting up SRS'

  postconf 'sender_canonical_maps = tcp:localhost:10001'
  postconf "sender_canonical_classes = ${SRS_SENDER_CLASSES}"
  postconf 'recipient_canonical_maps = tcp:localhost:10002'
  postconf 'recipient_canonical_classes = envelope_recipient,header_recipient'

  function __generate_secret
  {
    (
      umask 0077
      dd if=/dev/urandom bs=24 count=1 2>/dev/null | base64 -w0 >"${1}"
    )
  }

  local POSTSRSD_SECRET_FILE POSTSRSD_STATE_DIR POSTSRSD_STATE_SECRET_FILE

  sed -i "s/localdomain/${SRS_DOMAINNAME}/g" /etc/default/postsrsd

  POSTSRSD_SECRET_FILE='/etc/postsrsd.secret'
  POSTSRSD_STATE_DIR='/var/mail-state/etc-postsrsd'
  POSTSRSD_STATE_SECRET_FILE="${POSTSRSD_STATE_DIR}/postsrsd.secret"

  if [[ -n ${SRS_SECRET} ]]
  then
    (
      umask 0077
      echo "${SRS_SECRET}" | tr ',' '\n' >"${POSTSRSD_SECRET_FILE}"
    )
  else
    if [[ ${ONE_DIR} -eq 1 ]]
    then
      if [[ ! -f ${POSTSRSD_STATE_SECRET_FILE} ]]
      then
        install -d -m 0775 "${POSTSRSD_STATE_DIR}"
        __generate_secret "${POSTSRSD_STATE_SECRET_FILE}"
      fi

      install -m 0400 "${POSTSRSD_STATE_SECRET_FILE}" "${POSTSRSD_SECRET_FILE}"
    elif [[ ! -f ${POSTSRSD_SECRET_FILE} ]]
    then
      __generate_secret "${POSTSRSD_SECRET_FILE}"
    fi
  fi

  if [[ -n ${SRS_EXCLUDE_DOMAINS} ]]
  then
    sed -i \
      "s/^#\?(SRS_EXCLUDE_DOMAINS=).*$/\1=${SRS_EXCLUDE_DOMAINS}/g" \
      /etc/default/postsrsd
  fi
}

function _setup_postfix_hostname
{
  _log 'debug' 'Applying hostname and domainname to Postfix'
  postconf "myhostname = ${HOSTNAME}"
  postconf "mydomain = ${DOMAINNAME}"
}

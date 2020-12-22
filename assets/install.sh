#!/bin/bash

#judgement
if [[ -a /etc/supervisor/conf.d/supervisord.conf ]]; then
  exit 0
fi

#supervisor
cat > /etc/supervisor/conf.d/supervisord.conf <<EOF
[supervisord]
nodaemon=true

[program:postfix]
command=/opt/postfix.sh

[program:rsyslog]
command=/usr/sbin/rsyslogd -n -c3
EOF

############
#  postfix
############
cat >> /opt/postfix.sh <<EOF
#!/bin/bash
service postfix start
tail -f /var/log/mail.log
EOF
chmod +x /opt/postfix.sh
postconf -e myhostname=$maildomain
postconf -F '*/*/chroot = n'

############
# SASL SUPPORT FOR CLIENTS
# The following options set parameters needed by Postfix to enable
# Cyrus-SASL support for authentication of mail clients.
############
# /etc/postfix/main.cf
postconf -e smtpd_sasl_auth_enable=yes
postconf -e broken_sasl_auth_clients=yes
postconf -e smtpd_recipient_restrictions=permit_sasl_authenticated,reject_unauth_destination
# smtpd.conf
cat >> /etc/postfix/sasl/smtpd.conf <<EOF
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN CRAM-MD5 DIGEST-MD5 NTLM
EOF
# sasldb2
echo $smtp_user | tr , \\n > /tmp/passwd
while IFS=':' read -r _user _pwd; do
  echo $_pwd | saslpasswd2 -c -p -u $maildomain $_user
done < /tmp/passwd
chown postfix.sasl /etc/sasldb2

############
# Enable TLS
############
if [[ -n "$(find /opt/ssl -iname *.crt)" && -n "$(find /opt/ssl -iname *.key)" ]]; then
  # /etc/postfix/main.cf
  postconf -e smtpd_tls_cert_file=$(find /opt/ssl -iname *.crt)
  postconf -e smtpd_tls_key_file=$(find /opt/ssl -iname *.key)
  
  # postconf -e smtpd_tls_cert_file=/opt/ssl/localhost.pem
  # postconf -e smtpd_tls_key_file=/opt/ssl/localhost-key.pem

  postconf -e smtpd_tls_eccert_file=$(find /opt/ssl -iname *.crt)
  postconf -e smtpd_tls_eckey_file=$(find /opt/ssl -iname *.key)
  
  postconf -e smtpd_tls_protocols=!SSLv2,!SSLv3,!TLSv1,!TLSv1.1
  postconf -e smtp_tls_protocols=!SSLv2,!SSLv3,!TLSv1,!TLSv1.1
  postconf -e smtpd_tls_mandatory_protocols=!SSLv2,!SSLv3,!TLSv1,!TLSv1.1
  postconf -e smtp_tls_mandatory_protocols=!SSLv2,!SSLv3,!TLSv1,!TLSv1.1
  #postconf -e tls_high_cipherlist=!aNULL:!eNULL:!CAMELLIA:HIGH:@STRENGTH
  postconf -e smtpd_tls_loglevel=4
  postconf -e smtp_tls_loglevel=4

  postconf -e inet_interfaces=all
  postconf -e smtpd_tls_mandatory_ciphers=high
  postconf -e smtp_tls_mandatory_ciphers=high
  postconf -e smtp_tls_ciphers=high
  postconf -e smtpd_tls_ciphers=high
  postconf -e smtp_tls_security_level=may
  postconf -e smtpd_tls_security_level=may

  postconf -e smtpd_tls_received_header=yes

  chmod 640 /opt/ssl/*.*
  chown root:postfix /opt/ssl/*.*
  
  # /etc/postfix/master.cf
  postconf -M submission/inet="submission   inet   n   -   n   -   -   smtpd"
  postconf -P "submission/inet/syslog_name=postfix/submission"
  postconf -P "submission/inet/smtpd_tls_security_level=may"
  postconf -P "submission/inet/smtpd_sasl_auth_enable=yes"
  postconf -P "submission/inet/milter_macro_daemon_name=ORIGINATING"
  postconf -P "submission/inet/smtpd_recipient_restrictions=permit_sasl_authenticated,reject_unauth_destination"
fi

#############
#  opendkim
#############

if [[ -z "$(find /etc/opendkim/domainkeys -iname *.private)" ]]; then
  exit 0
fi
cat >> /etc/supervisor/conf.d/supervisord.conf <<EOF

[program:opendkim]
command=/usr/sbin/opendkim -f
EOF
# /etc/postfix/main.cf
postconf -e milter_protocol=2
postconf -e milter_default_action=accept
postconf -e smtpd_milters=inet:localhost:12301
postconf -e non_smtpd_milters=inet:localhost:12301

cat >> /etc/opendkim.conf <<EOF
AutoRestart             Yes
AutoRestartRate         10/1h
UMask                   002
Syslog                  yes
SyslogSuccess           Yes
LogWhy                  Yes

Canonicalization        relaxed/simple

ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable

Mode                    sv
PidFile                 /var/run/opendkim/opendkim.pid
SignatureAlgorithm      rsa-sha256

UserID                  opendkim:opendkim

Socket                  inet:12301@localhost
EOF
cat >> /etc/default/opendkim <<EOF
SOCKET="inet:12301@localhost"
EOF

cat >> /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
192.168.0.1/24

*.$maildomain
EOF
cat >> /etc/opendkim/KeyTable <<EOF
mail._domainkey.$maildomain $maildomain:mail:$(find /etc/opendkim/domainkeys -iname *.private)
EOF
cat >> /etc/opendkim/SigningTable <<EOF
*@$maildomain mail._domainkey.$maildomain
EOF
chown opendkim:opendkim $(find /etc/opendkim/domainkeys -iname *.private)
chmod 400 $(find /etc/opendkim/domainkeys -iname *.private)
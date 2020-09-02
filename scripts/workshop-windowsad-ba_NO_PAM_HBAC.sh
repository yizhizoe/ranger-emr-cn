#!/usr/bin/env bash

###################### CHANGE THE FOLLOWING VARIABLES ###########################
# Active Directory domain name. Set this to your AD domain name.
KRB5_REALM='uclek.com'

# FQDN of the AD domain controller. Set this to the hostname of your domain controller.
KDC_SERVER='WIN-PCI83FHJJ98.uclek.com'

# Cross-realm trust password. Set this to the trust password that you have created
# (Ref: https://docs.aws.amazon.com/emr/latest/ManagementGuide/emr-kerberos-cross-realm.html#emr-kerberos-ad-configure-trust)
TRUST_PASS='Aws@1234'

# Set this to your ad/ldap search base
LDAP_SEARCH_BASE='dc=uclek,dc=com'

# Set this to your LDAP bind user (user that will perform LDAP searches for user lookup)
BIND_USER='binduser'

# AD bind user password. Set this to your bind user's password.
BIND_USER_PASS='*Aws@1234!'

# Set this to the IP address of your domain controller. If domain controller is the DNS server for the EMR nodes, you can leave this empty.
KDC_SERVER_IP='172.31.46.230'

# Set this to your FreeIPA sudo OU
LDAP_SUDO_SEARCH_BASE='cn=users,dc=uclek,dc=com'
#################################################################################


IDP="ad"
UPPER_CASE_KRB5_REALM=$(echo ${KRB5_REALM} | tr '[a-z]' '[A-Z]')
SSSD_PUPPET_DIR='/var/aws/emr/bigtop-deploy/puppet/modules/sssd'
SSSD_PUPPET_TEMPLATE="${SSSD_PUPPET_DIR}/templates/sssd.conf.erb"
CLUSTER_YAML='/var/aws/emr/bigtop-deploy/puppet/hieradata/bigtop/cluster.yaml'
#CLUSTER_YAML='/etc/puppet/hieradata/bigtop/cluster.yaml'

if [[ ! "$IDP" =~ ^(freeipa|ad|ldap)$ ]] ; then
  echo "Identity provider $IDP not found"
  echo "Available identity providers: ad, freeipa, ldap"
  exit 1
fi

echo "Configuring SSSD for identity provider: $IDP"

enable_sssd_puppet_config() {
sudo sed -i "s/rdns =.*/rdns = false/" /var/aws/emr/bigtop-deploy/puppet/modules/kerberos/templates/krb5.conf
sudo bash -c "cat > /tmp/kerberosSSSD.tmp" <<'EOF'
    include sssd

EOF
sudo sed -i "/class client inherits kerberos::site/r /tmp/kerberosSSSD.tmp" /var/aws/emr/bigtop-deploy/puppet/modules/kerberos/manifests/init.pp
}
enable_sssd_puppet_config

sssd_configuration_variables() {
sudo bash -c "cat >> ${CLUSTER_YAML}" <<EOF

sssd::krb5_realm: '${KRB5_REALM}'
sssd::ldap_search_base: "${LDAP_SEARCH_BASE}"
sssd::idp: "${IDP}"
sssd::bind_user: "${BIND_USER}"
sssd::bind_user_pass: "${BIND_USER_PASS}"
sssd::kdc_server: '${KDC_SERVER}'
sssd::kdc_server_ip: "${KDC_SERVER_IP}"
sssd::ldap_sudo_search_base: "${LDAP_SUDO_SEARCH_BASE}"

EOF
}
sssd_configuration_variables

cross_realm_trust_config() {
sudo bash -c "cat >> ${CLUSTER_YAML}" <<EOF

kerberos::site::cross_realm_trust_kdc_server: '${KDC_SERVER}'
kerberos::site::cross_realm_trust_principal_password: '${TRUST_PASS}'
kerberos::site::cross_realm_trust_admin_server: '${KDC_SERVER}'
kerberos::site::cross_realm_trust_enabled: 'true'
kerberos::site::cross_realm_trust_realm: '${UPPER_CASE_KRB5_REALM}'
kerberos::site::cross_realm_trust_domain: '${KRB5_REALM}'

EOF
}
cross_realm_trust_config

configure_sssd_puppet() {
sudo mkdir -p ${SSSD_PUPPET_DIR}/manifests
sudo mkdir -p ${SSSD_PUPPET_DIR}/templates

sudo puppet module install herculesteam-augeasproviders_pam

sudo bash -c "cat > ${SSSD_PUPPET_DIR}/manifests/init.pp" <<'EOF'
class sssd (
   $krb5_realm = '',
   $ldap_search_base = '',
   $ldap_sudo_search_base = '',
   $idp = '',
   $bind_user = '',
   $bind_user_pass = '',
   $kdc_server = '',
   $kdc_server_ip = '') {

  $realm = upcase($krb5_realm)
  $exec_path = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

  require kerberos::client
  Class['kerberos::client'] -> Class['sssd']

  package { 'sssd':
    ensure => installed,
  }

  package { 'oddjob-mkhomedir':
    ensure => installed,
  }

  package { 'ruby20-augeas':
    ensure => installed,
  }

  file {'/etc/sssd/sssd.conf':
    notify => Service["sssd"],
    ensure => file,
    mode   => 0600,
    owner  => root,
    group  => root,
    require => Package["sssd"],
    content => template("sssd/sssd.conf.erb"),
  }

  file { "/etc/sssd":
    ensure => "directory",
  }

  exec { "createkeytab":
    path     => $exec_path,
    command  => "ktutil <<kutilEOF
      addent -password -p $bind_user@$realm -k 1 -e aes256-cts-hmac-sha1-96
$bind_user_pass
      write_kt /etc/krb5.keytab
      q
kutilEOF
        ",
      creates => '/etc/krb5.keytab',
  }

  exec { "enable_sssd_pam":
    path => $exec_path,
    command => "authconfig --update --enablesssd --enablesssdauth --enablemkhomedir",
    require => [ Package['sssd'], Package['oddjob-mkhomedir'] ],
  }

  if ($idp == 'freeipa') {
    exec { "add_sudoers_to_nsswitch":
      path => $exec_path,
      command => 'sed -i "/^group.*/a sudoers: \ \ \ files sss" /etc/nsswitch.conf',
      require => [ Exec["enable_sssd_pam"] ],
    }
  }

  augeas { 'ssh_password_authentication':
    context => '/files/etc/ssh/sshd_config',
    changes => [
      "set PasswordAuthentication yes"
    ],
    require => Package['ruby20-augeas'],
  }

  if ($kdc_server_ip != '') {
      augeas { "kdcserver_in_hosts_append":
        context => "/files/etc/hosts",
        changes => [
            "set 01/ipaddr '${kdc_server_ip}'",
            "set 01/canonical '${kdc_server}'",
        ],
        onlyif => "match *[ipaddr = '${kdc_server_ip}'] size == 0"
      } -> augeas { "kdcserver_in_hosts_update":
        context => "/files/etc/hosts",
        changes => [
            "set *[ipaddr = '${kdc_server_ip}']/canonical '${kdc_server}'",
        ],
        onlyif => "match *[ipaddr = '${kdc_server_ip}'] size > 0",
        require => Augeas["kdcserver_in_hosts_append"];
      }
  }

  service { "sshd":
    ensure     => running,
    subscribe  => Augeas['ssh_password_authentication'],
    hasrestart => true,
  }

  service { 'sssd':
    ensure => running,
    enable => true,
    provider => 'redhat',
    require => [ Package["sssd"], File["/etc/sssd/sssd.conf"], Exec["createkeytab"] ],
  }
}

EOF
}
configure_sssd_puppet

sssd_conf_template() {
sudo bash -c "cat > ${SSSD_PUPPET_TEMPLATE}" <<'EOF'
[sssd]
config_file_version = 2
services = nss, pam, sudo, ssh
domains = <%= @krb5_realm %>

[nss]
filter_groups = root
filter_users = root
reconnection_retries = 3

[pam]

[domain/<%= @krb5_realm %>]
debug_level = 7

override_homedir = /home/%u@%d
override_shell = /bin/bash

enumerate = False
case_sensitive = false
cache_credentials = True
use_fully_qualified_names = False

<% if @idp == 'freeipa' -%>
ipa_domain = <%= @krb5_realm %>
ipa_hostname = <%= @kdc_server %>
ldap_schema = rfc2307
ldap_uri = ldap://<%= @kdc_server_ip %>
ldap_search_base = <%= @ldap_search_base %>

id_provider = ldap
auth_provider = krb5
chpass_provider = none

krb5_realm = <%= @realm %>
krb5_server = <%= @kdc_server_ip %>

# Sudo configuration
sudo_provider = ldap
ldap_sudo_search_base = <%= @ldap_sudo_search_base %>
ldap_sudo_full_refresh_interval=86400
ldap_sudo_smart_refresh_interval=3600
<% end -%>

<% if @idp == 'ad' -%>
min_id = 1000
ldap_id_mapping = True

id_provider = ldap
auth_provider = krb5
chpass_provider = none
access_provider = permit

ldap_tls_reqcert = allow
ldap_schema = ad
ldap_sasl_mech = GSSAPI
ldap_sasl_authid = <%= @bind_user %>@<%= @realm %>
krb5_fast_principal = <%= @bind_user %>@<%= @realm %>
krb5_use_fast = try
krb5_canonicalize = false

ldap_access_order = expire
ldap_account_expire_policy = ad
ldap_force_upper_case_realm = true

ldap_pwd_policy = none
krb5_realm = <%= @realm %>
ldap_uri = ldap://<%= @kdc_server %>
ldap_search_base = <%= @ldap_search_base %>
<% end -%>

EOF
}
sssd_conf_template

configure_pam_hbac() {
sudo bash -c "cat > /etc/yum.repos.d/jhrozek-pam_hbac-epel-6.repo" <<'EOF'
[jhrozek-pam_hbac]
name=Copr repo for pam_hbac owned by jhrozek
baseurl=https://copr-be.cloud.fedoraproject.org/results/jhrozek/pam_hbac/epel-6-$basearch/
type=rpm-md
skip_if_unavailable=True
gpgcheck=1
gpgkey=https://copr-be.cloud.fedoraproject.org/results/jhrozek/pam_hbac/pubkey.gpg
repo_gpgcheck=0
enabled=1
enabled_metadata=1
EOF

sudo bash -c "cat > /etc/pam_hbac.conf" <<'EOF'
URI = ldap://10.0.1.140
BASE = dc=bruno,dc=com
BIND_DN = uid=hbac,cn=sysaccounts,cn=etc,dc=bruno,dc=com
BIND_PW = Pass123!
#SSL_PATH = /etc/openldap/cacerts/ipa.crt
HOST_NAME = emrmaster.bruno.com
EOF

sudo mkdir -p /etc/openldap
sudo bash -c "cat >> /etc/openldap/ldap.conf" <<'EOF'
SASL_NOCANON on
TLS_REQCERT allow
EOF
}
#configure_pam_hbac


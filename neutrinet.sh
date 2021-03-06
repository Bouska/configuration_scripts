#!/bin/bash

dummy_pwd=neutrinet

cat <<EOF

You are about to configure an Internet Cube for Neutrinet.
All the passwords will be: '$dummy_pwd' (to change after this script's execution)

/!\\ This script has to be run as root *on* the Cube itself, on a labriqueinternet_A20LIME_2015-11-09.img SD card (or newer)
/!\\ If you run into trouble, please refer to the original documentation page: https://yunohost.org/installation_brique_fr

EOF

# Exit if any of the following command fails
set -e

get_variables() {

    if [ -f neutrinet.variables ]; then
        source neutrinet.variables
    else
        echo
        echo "Main domain name (will be used to host your email and services)"
        echo "i.e.: example.com"
        read domain
        echo
        echo "Username (used to connect to the user interface and access your apps, must be composed of lowercase letters and numbers only)"
        echo "i.e.: jonsnow"
        read username
        echo
        echo "Firstname (mandatory, used as your firstname when you send emails)"
        echo "i.e.: Jon"
        read firstname
        echo
        echo "Lastname (mandatory, used as your lastname when you send emails)"
        echo "i.e. Snow"
        read lastname
        echo
        echo "Email (must contain one of the domain previously entered as second part)"
        echo "i.e. jon@example.com"
        read email
        echo
        echo "VPN client certificate (paste all the content of client.crt below and end with a blank line): "
        vpn_client_crt=$(sed '/^$/q' | sed 's/-----BEGIN CERTIFICATE-----//' | sed 's/-----END CERTIFICATE-----//' | sed '/^$/d')
        echo
        echo "VPN client key (paste all the content of client.key below and end with a blank line): "
        vpn_client_key=$(sed '/^$/q' | sed 's/-----BEGIN PRIVATE KEY-----//' | sed 's/-----END PRIVATE KEY-----//' | sed '/^$/d')
        echo
        echo "CA server certificate (paste all the content of ca.crt below and end with a blank line): "
        vpn_ca_crt=$(sed '/^$/q' | sed 's/-----BEGIN CERTIFICATE-----//' | sed 's/-----END CERTIFICATE-----//' | sed '/^$/d')
        echo
        echo "VPN username: "
        read vpn_username
        echo
        echo "VPN password: "
        read vpn_pwd
        echo
        echo "IPv6 delegated prefix (without trailing /56, to be found in the neutrinet MGMT interface)"
        echo "i.e.: 2001:913:1000:300::"
        read ip6_net
        echo
        echo "WiFi AP SSID (that will appear right after this configuration script ending)"
        echo "i.e.: MyWunderbarNeutralNetwork"
        read wifi_ssid
        echo
        echo "Install DKIM? (recommended if you want a perfect email server, not needed otherwise)"
        echo "(Yes/No)"
        read install_dkim
        echo
        echo
        echo "The installation will proceed, please verify the parameters above one last time."
        read -rsp $'Press any key to continue...\n' -n1 yolo
        echo

        # Store all the variables into a file
        for var in domain username firstname lastname email vpn_username vpn_pwd ip6_net wifi_ssid; do
            declare -p $var | cut -d ' ' -f 3- >> neutrinet.variables
        done

        echo "vpn_client_crt=\"$vpn_client_crt\"" >> neutrinet.variables
        echo "vpn_client_key=\"$vpn_client_key\"" >> neutrinet.variables
        echo "vpn_ca_crt=\"$vpn_ca_crt\"" >> neutrinet.variables
    fi
}

modify_hosts() {
    # to resolve the domain properly
    echo "Modifying hosts..."

    grep -q "olinux" /etc/hosts \
      || echo "127.0.0.1 $domain olinux" >> /etc/hosts
}

upgrade_system() {
    echo "Upgrading Debian packages..."

    echo "deb http://repo.yunohost.org/debian jessie stable" > /etc/apt/sources.list.d/yunohost.list

    apt-get update -qq
    apt-get dist-upgrade -y
}

postinstall_yunohost() {
    echo "Launching YunoHost post-installation..."

    yunohost tools postinstall -d $domain -p $dummy_pwd
}

create_yunohost_user() {
    echo "Creating the first YunoHost user..."

    yunohost user create $username -f "$firstname" -l "$lastname" -m $email \
      -q 0 -p $dummy_pwd
}

install_vpnclient() {
    echo "Installing the VPN client application..."

    yunohost app install https://github.com/labriqueinternet/vpnclient_ynh \
      --args "domain=$domain&path=/vpnadmin&server_name=vpn.neutrinet.be"
}


configure_vpnclient() {
    echo "Configuring the VPN connection..."

    # Restrict user access to the app
    yunohost app addaccess vpnclient -u $username

    # Neutrinet related: add some VPN configuration directives
    cat >> /etc/openvpn/client.conf.tpl <<EOF

resolv-retry infinite
ns-cert-type server
topology subnet
EOF

    # Copy certificates and keys
    mkdir -p /etc/openvpn/keys
    echo '-----BEGIN CERTIFICATE-----'             > /etc/openvpn/keys/user.crt
    grep -Eo '"[^"]*"|[^" ]*' <<< $vpn_client_crt >> /etc/openvpn/keys/user.crt
    echo '-----END CERTIFICATE-----'              >> /etc/openvpn/keys/user.crt

    echo '-----BEGIN PRIVATE KEY-----'             > /etc/openvpn/keys/user.key
    grep -Eo '"[^"]*"|[^" ]*' <<< $vpn_client_key >> /etc/openvpn/keys/user.key
    echo '-----END PRIVATE KEY-----'              >> /etc/openvpn/keys/user.key

    echo '-----BEGIN CERTIFICATE-----'             > /etc/openvpn/keys/ca-server.crt
    grep -Eo '"[^"]*"|[^" ]*' <<< $vpn_ca_crt     >> /etc/openvpn/keys/ca-server.crt
    echo '-----END CERTIFICATE-----'              >> /etc/openvpn/keys/ca-server.crt

    # And credentials
    echo -e "$vpn_username\n$vpn_pwd" > /etc/openvpn/keys/credentials

    # Set rights
    chown admin:admins -hR /etc/openvpn/keys
    chmod 640 -R /etc/openvpn/keys

    # Configure VPN client
    yunohost app setting vpnclient server_name -v "vpn.neutrinet.be"
    yunohost app setting vpnclient server_port -v "1194"
    yunohost app setting vpnclient server_proto -v "udp"
    yunohost app setting vpnclient service_enabled -v "1"

    yunohost app setting vpnclient login_user -v "$vpn_username"
    yunohost app setting vpnclient login_passphrase -v "$vpn_pwd"

    yunohost app setting vpnclient ip6_net -v "$ip6_net"

    # Add the service to YunoHost's monitored services
    yunohost service add ynh-vpnclient -l /var/log/openvpn-client.log

    echo "Restarting OpenVPN..."
    systemctl restart ynh-vpnclient \
      || (echo "Logs:" && cat /var/log/openvpn-client.log && exit 1)
    sleep 5
}


install_hotspot() {
    echo "Installing the Hotspot application..."

    yunohost app install https://github.com/labriqueinternet/hotspot_ynh \
      --args "domain=$domain&path=/wifiadmin&wifi_ssid=$wifi_ssid&wifi_passphrase=$dummy_pwd&firmware_nonfree=yes"
}


configure_hostpot() {
    echo "Configuring the hotspot..."

    # Removing the persistent Net rules to keep the Wifi device to wlan0
    rm -f /etc/udev/rules.d/70-persistent-net.rules

    # Restrict user access to the app
    yunohost app addaccess hotspot -u $username

    # Ensure that the hotspot is activated and that the IPv6 prefix is set
    yunohost app setting hotspot service_enabled -v "1"
    yunohost app setting hotspot ip6_net -v "$ip6_net"
    yunohost app setting hotspot ip6_addr -v "${ip6_net}42"

    # Add the service to YunoHost's monitored services
    yunohost service add ynh-hotspot -l /var/log/syslog

    echo "Restarting the hotspot..."
    systemctl restart ynh-hotspot
}


# ----------------------------------
# Optional steps
# ----------------------------------

remove_dyndns_cron() {
    yunohost dyndns update > /dev/null 2>&1 \
      && echo "Removing the DynDNS cronjob..." \
      || echo "No DynDNS to remove"

    rm -f /etc/cron.d/yunohost-dyndns
}

restart_api() {
    systemctl restart yunohost-api
}

configure_DKIM() {
    if [ "$install_dkim" = "Yes" ]; then
        echo "Configuring the DKIM..."

        # Install OpenDKIM
        apt-get install -y opendkim opendkim-tools > /dev/null 2>&1;

        # Create OpenDKIM config
        cat > /etc/opendkim.conf <<EOF

AutoRestart Yes
AutoRestartRate 10/1h
UMask 022
Syslog yes
SyslogSuccess Yes
LogWhy Yes

Canonicalization relaxed/simple

ExternalIgnoreList refile:/etc/opendkim/TrustedHosts
InternalHosts refile:/etc/opendkim/TrustedHosts
KeyTable refile:/etc/opendkim/KeyTable
SigningTable refile:/etc/opendkim/SigningTable

Mode sv
PidFile /var/run/opendkim/opendkim.pid
SignatureAlgorithm rsa-sha256

UserID opendkim:opendkim

Socket inet:8891@127.0.0.1

Selector mail

EOF

        # Configure OpenDKIM's socket
        echo sudo echo "SOCKET=\"inet:8891@localhost\"" >> /etc/default/opendkim

        # Configure postfix to use OpenDKIM
        cat >> /etc/postfix/main.cf <<EOF
# OpenDKIM milter
milter_protocol = 2
milter_default_action = accept
smtpd_milters = inet:127.0.0.1:8891
non_smtpd_milters = inet:127.0.0.1:8891
EOF

        # Add TrustedHosts
        cat > /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
10.0.0.0/8
*.$domain
EOF

        # Add Keytable
        echo "mail._domainkey.$domain $domain:mail:/etc/opendkim/keys/$domain/mail.private" > /etc/opendkim/KeyTable

        # Add SigningTable
        echo "*@$domain mail._domainkey.$domain" > /etc/opendkim/SigningTable

        # Create DKIM keys
        mkdir -pv /etc/opendkim/keys/$domain
        cd /etc/opendkim/keys/$domain
        opendkim-genkey -s mail -d $domain

        # Set rights
        chown -Rv opendkim:opendkim /etc/opendkim*

        # Restart OpenDKIM & postfix
        echo "Restarting OpenDKIM & postfix..."
        service opendkim restart
        service postfix restart

    fi
}

display_win_message() {
    ip6=$(ip -6 addr show tun0 | awk -F'[/ ]' '/inet/{print $6}' || echo 'ERROR')
    ip4=$(ip -4 addr show tun0 | awk -F'[/ ]' '/inet/{print $6}' || echo 'ERROR')

    cat <<EOF

VICTOIRE !

Your Cube has been configured properly. Please set your DNS records as below:

$(for ip in $ip4 $ip6; do echo "@ 14400 IN A $ip"; echo "* 14400 IN A $ip"; done;)

_xmpp-client._tcp 14400 IN SRV 0 5 5222 $domain.
_xmpp-server._tcp 14400 IN SRV 0 5 5269 $domain.

@ 14400 IN MX 5 $domain.
@ 14400 IN TXT "v=spf1 a mx $(for ip in $ip4; do echo -n "ip4:$ip "; done;) $(for ip in $ip6; do echo -n "ip6:$ip "; done;) -all"

$(cat /etc/opendkim/keys/$domain/mail.txt > /dev/null 2>&1 || echo '')
_dmarc 14400 IN TXT "v=DMARC1; p=none; rua=mailto:postmaster@$domain"

EOF

    cat <<EOF

/!\\ Do not forget to change:
  * The administration password
  * The user password
  * The root password
  * The Wifi AP password
EOF

}


# ----------------------------------
# Operation order (you can deactivate some if your script has failed in the middle)
# ----------------------------------

get_variables

modify_hosts
upgrade_system

postinstall_yunohost
create_yunohost_user
install_vpnclient
configure_vpnclient
install_hotspot
configure_hostpot

remove_dyndns_cron
restart_api
configure_DKIM

display_win_message

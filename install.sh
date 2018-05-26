#!/bin/bash

if [[ $(id -u) != "0" ]]; then
    printf "\e[42m\e[31mError: You must be root to run this install script.\e[0m\n"
    exit 1
fi

if [[ $(grep "release 7." /etc/redhat-release 2>/dev/null | wc -l) -eq 0 ]]; then
    printf "\e[42m\e[31mError: Your OS is NOT CentOS 7 or RHEL 7.\e[0m\n"
    printf "\e[42m\e[31mThis install script is ONLY for CentOS 7 and RHEL 7.\e[0m\n"
    exit 1
fi

basepath=$(dirname $0)
cd ${basepath}

function ConfigEnvironmentVariable {
    ocserv_version="0.11.0"
    version=${1-${ocserv_version}}
    libtasn1_version=4.7
    maxsameclients=5
    maxclients=512
    servercert=${2-server-cert.pem}
    serverkey=${3-server-key.pem}
    confdir="/usr/local/etc/ocserv"
    dns_ip="192.168.1.1"
    port=443
    ipv4_network="192.168.8.0"
    ipv4_netmask="255.255.248.0"
    make_flag="-j8"
}

function CompileOcserv {
    yum install -y -q epel-release
    yum install -y gnutls gnutls-utils gnutls-devel readline readline-devel \
    libnl-devel libtalloc libtalloc-devel libnl3-devel wget \
    pam pam-devel libtalloc-devel xz libseccomp-devel \
    tcp_wrappers-devel autogen autogen-libopts-devel tar \
    gcc pcre-devel openssl openssl-devel curl-devel \
    lz4-devel lz4 radcli-compat-devel radcli systemd-devel \
    http-parser-devel http-parser protobuf-c-devel protobuf-c \
    pcllib-devel pcllib cyrus-sasl-gssapi dbus-devel policycoreutils gperf \
    libev-devel net-tools bind-utils

:<<_EOF_
    wget -t 0 -T 60 "http://ftp.gnu.org/gnu/libtasn1/libtasn1-${libtasn1_version}.tar.gz"
    tar axf libtasn1-${libtasn1_version}.tar.gz
    cd libtasn1-${libtasn1_version}
    ./configure --prefix=/usr --libdir=/usr/lib64 --includedir=/usr/include
    make && make install
    cd ..
_EOF_

    wget -t 0 -T 60 "ftp://ftp.infradead.org/pub/ocserv/ocserv-${version}.tar.xz"
    tar axf ocserv-${version}.tar.xz
    cd ocserv-${version}
    ./configure && make ${make_flag} && make install

    mkdir -p "${confdir}"
    cp "doc/sample.config" "${confdir}/ocserv.conf"
    cp "doc/systemd/standalone/ocserv.service" "/usr/lib/systemd/system/ocserv.service"
    cd ${basepath}
}

function ConfigOcserv {
    if [[ ! -f "${servercert}" ]] || [[ ! -f "${serverkey}" ]]; then
        certtool --generate-privkey --outfile ca-key.pem

        cat << _EOF_ >ca.tmpl
cn = "Tursted Cloud Group SJTU"
organization = "Trusted Cloud Group SJTU"
serial = 1
expiration_days = 3650
ca
signing_key
cert_signing_key
crl_signing_key
_EOF_

        certtool --generate-self-signed --load-privkey ca-key.pem \
        --template ca.tmpl --outfile ca-cert.pem
        certtool --generate-privkey --outfile ${serverkey}

        cat << _EOF_ >server.tmpl
cn = "202.120.40.100"
o = "Trusted Cloud Group SJTU"
serial = 2
expiration_days = 3650
signing_key
encryption_key #only if the generated key is an RSA one
tls_www_server
_EOF_

        certtool --generate-certificate --load-privkey ${serverkey} \
        --load-ca-certificate ca-cert.pem --load-ca-privkey ca-key.pem \
        --template server.tmpl --outfile ${servercert}
    fi

    cp "${servercert}" "${confdir}" && cp "${serverkey}" "${confdir}"

    sed -i "s#/usr/sbin/ocserv#/usr/local/sbin/ocserv#g" "/usr/lib/systemd/system/ocserv.service"
    sed -i "s#/etc/ocserv/ocserv.conf#$confdir/ocserv.conf#g" "/usr/lib/systemd/system/ocserv.service"

    cat << _EOF_ >${confdir}/ocserv.conf
auth = "pam"
tcp-port = ${port}
udp-port = ${port}
run-as-user = nobody
run-as-group = nobody
socket-file = /var/run/ocserv-socket
server-cert = ${confdir}/${servercert}
server-key = ${confdir}/${serverkey}
isolate-workers = true
max-clients = ${maxclients}
max-same-clients = ${maxsameclients}
keepalive = 32400
dpd = 90
mobile-dpd = 1800
try-mtu-discovery = false
cert-user-oid = 0.9.2342.19200300.100.1.1
tls-priorities = "NORMAL:%SERVER_PRECEDENCE:%COMPAT:-VERS-SSL3.0"
auth-timeout = 240
min-reauth-time = 300
max-ban-score = 50
ban-reset-time = 300
cookie-timeout = 86400
cookie-rekey-time = 14400
deny-roaming = false
rekey-time = 172800
rekey-method = ssl
use-occtl = true
pid-file = /var/run/ocserv.pid
device = vpns
predictable-ips = true
#default-domain = example.com
ipv4-network = ${ipv4_network}
ipv4-netmask = ${ipv4_netmask}
dns = ${dns_ip}
ping-leases = true
cisco-client-compat = true
user-profile = /usr/local/etc/ocserv/profile.xml
_EOF_

    cat << _EOF_ >/etc/pam.d/ocserv
uth       include	password-auth
account    required	pam_nologin.so
account    include	password-auth
session    include	password-auth
_EOF_
}

function ConfigFirewall {

firewalldisactive=$(systemctl is-active firewalld.service)
iptablesisactive=$(systemctl is-active iptables.service)

if [[ ${firewalldisactive} = 'active' ]]; then
    echo "Adding firewall ports."
    firewall-cmd --permanent --add-port=${port}/tcp
    firewall-cmd --permanent --add-port=${port}/udp
    echo "Allow firewall to forward."
    firewall-cmd --permanent --add-masquerade
    echo "Reload firewall configure."
    firewall-cmd --reload
elif [[ ${iptablesisactive} = 'active' ]]; then
    iptables -I INPUT -p tcp --dport ${port} -j ACCEPT
    iptables -I INPUT -p udp --dport ${port} -j ACCEPT
    iptables -A FORWARD -s 192.168.8.0/21 -j ACCEPT
    iptables -t nat -A POSTROUTING -s 192.168.8.0/21 -j MASQUERADE
    service iptables save
else
    printf "\e[33mWARNING!!! Either firewalld or iptables is NOT Running! \e[0m\n"
fi
}

function ConfigSystem {
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
    setenforce 0
    echo "Enable IP forward."
    sysctl -w net.ipv4.ip_forward=1
    echo net.ipv4.ip_forward = 1 >> "/etc/sysctl.conf"
    systemctl daemon-reload
    echo "Enable ocserv service to start during bootup."
    systemctl enable ocserv.service
    systemctl start ocserv.service
    echo
}

function PrintResult {
    printf "\e[36mChenking Firewall status...\e[0m\n"
    iptables -L -n | grep --color=auto -E "(${port}|192.168.8.0)"
    line=$(iptables -L -n | grep -c -E "(${port}|192.168.8.0)")
    if [[ ${line} -ge 2 ]]
    then
        printf "\e[34mFirewall is Fine! \e[0m\n"
    else
        printf "\e[33mWARNING!!! Firewall is Something Wrong! \e[0m\n"
    fi

    echo
    printf "\e[36mChenking ocserv service status...\e[0m\n"
    netstat -anp | grep ":${port}" | grep --color=auto -E "(${port}|ocserv|tcp|udp)"
    linetcp=$(netstat -anp | grep ":${port}" | grep ocserv | grep tcp | wc -l)
    lineudp=$(netstat -anp | grep ":${port}" | grep ocserv | grep udp | wc -l)
    if [[ ${linetcp} -ge 1 && ${lineudp} -ge 1 ]]
    then
        printf "\e[34mocserv service is Fine! \e[0m\n"
    else
        printf "\e[33mWARNING!!! ocserv service is NOT Running! \e[0m\n"
    fi
}

ConfigEnvironmentVariable
CompileOcserv $@
ConfigOcserv
ConfigFirewall
ConfigSystem
PrintResult
exit 0

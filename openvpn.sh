#!/bin/bash
set -e

# ========= Variables =========
VPN_NET="10.8.0.0"
VPN_MASK="255.255.255.0"
PRIVATE_SUBNETS=("10.0.11.0 255.255.255.0" "10.0.12.0 255.255.255.0")
VPN_PORT=1194
VPN_PROTO=udp
VPN_USERDB=/etc/openvpn/auth/users.txt
CHECK_PSW=/etc/openvpn/auth/checkpsw.sh
CLIENT_OUTPUT_DIR=~/vpn-clients
USERS=("senthilr:mypassword" "ram:secret123")

# ========= Update & Install Packages =========
echo "[INFO] Updating system and installing packages..."
sudo dnf update -y
sudo dnf install -y openvpn iptables iproute git tar gzip zip pam-devel

# ========= Install Easy-RSA =========
echo "[INFO] Installing Easy-RSA..."
sudo mkdir -p /usr/local/share
if [ ! -d /usr/local/share/easy-rsa ]; then
    sudo git clone https://github.com/OpenVPN/easy-rsa.git /usr/local/share/easy-rsa
fi
sudo ln -sf /usr/local/share/easy-rsa/easyrsa3/easyrsa /usr/local/bin/easyrsa

# ========= Setup PKI and Certificates =========
echo "[INFO] Generating OpenVPN PKI..."
mkdir -p ~/openvpn-ca
cd ~/openvpn-ca
easyrsa init-pki
(echo; echo; echo) | easyrsa build-ca nopass
easyrsa gen-dh
easyrsa build-server-full server nopass
easyrsa gen-crl

sudo mkdir -p /etc/openvpn/server
sudo cp pki/ca.crt pki/private/server.key pki/issued/server.crt pki/dh.pem pki/crl.pem /etc/openvpn/server/

# ========= Configure OpenVPN Server =========
echo "[INFO] Configuring OpenVPN server..."
sudo tee /etc/openvpn/server/server.conf >/dev/null <<EOF
port $VPN_PORT
proto $VPN_PROTO
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
crl-verify crl.pem

topology subnet
server $VPN_NET $VPN_MASK

# Push routes to VPN clients for private subnets
$(for subnet in "${PRIVATE_SUBNETS[@]}"; do echo "push \"route $subnet\""; done)

# Enable username/password authentication using file
auth-user-pass-verify $CHECK_PSW via-env
verify-client-cert none
username-as-common-name
keepalive 10 120
persist-key
persist-tun
user nobody
group nobody
status /var/log/openvpn-status.log
log-append /var/log/openvpn.log
verb 3
EOF

# ========= Enable IP Forwarding =========
echo "[INFO] Enabling IP forwarding..."
sudo tee -a /etc/sysctl.conf <<EOF
net.ipv4.ip_forward = 1
EOF
sudo sysctl -p

# ========= Configure NAT =========
echo "[INFO] Configuring NAT..."
IFACE=$(ip route | grep default | awk '{print $5}')
sudo iptables -t nat -A POSTROUTING -s $VPN_NET/24 -o $IFACE -j MASQUERADE
sudo iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -s $VPN_NET/24 -j ACCEPT
sudo dnf install -y iptables-services
sudo service iptables save
sudo systemctl enable iptables

# ========= Create User Authentication =========
echo "[INFO] Creating user database and check script..."
sudo mkdir -p /etc/openvpn/auth
sudo tee $VPN_USERDB >/dev/null <<EOF
$(for u in "${USERS[@]}"; do echo "$u"; done)
EOF
sudo chmod 600 $VPN_USERDB

sudo tee $CHECK_PSW >/dev/null <<'EOF'
#!/bin/bash
USER_PASS_FILE="/etc/openvpn/auth/users.txt"
if grep -q "^$username:$password$" "$USER_PASS_FILE"; then
    exit 0
else
    exit 1
fi
EOF

sudo chmod 700 $CHECK_PSW
sudo chown root:root $CHECK_PSW

# ========= Enable & Start OpenVPN =========
echo "[INFO] Starting OpenVPN server..."
sudo systemctl daemon-reexec
sudo systemctl enable openvpn-server@server
sudo systemctl restart openvpn-server@server
sudo systemctl status openvpn-server@server --no-pager || true

# ========= Generate Client Config Files =========
echo "[INFO] Generating client .ovpn files..."
mkdir -p $CLIENT_OUTPUT_DIR
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
CA_CERT=$(sudo cat /etc/openvpn/server/ca.crt)

for u in "${USERS[@]}"; do
    USERNAME="${u%%:*}"
    cat > $CLIENT_OUTPUT_DIR/${USERNAME}.ovpn <<EOF
client
dev tun
proto udp
remote $PUBLIC_IP $VPN_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
auth-user-pass
cipher AES-256-CBC
auth SHA256
remote-cert-tls server
verify-x509-name server name
verb 3

<ca>
$CA_CERT
</ca>
EOF
done

# ========= Zip client profiles for easy download =========
cd $CLIENT_OUTPUT_DIR
zip vpn-profiles.zip *.ovpn

echo "[INFO] Client profiles generated at: $CLIENT_OUTPUT_DIR"
ls -l $CLIENT_OUTPUT_DIR

echo "[INFO] OpenVPN setup complete! Download vpn-profiles.zip to your local machine using scp."
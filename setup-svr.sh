#!/bin/bash

echo "========================================"
echo "   SETUP SERVER - MODE INTERAKTIF"
echo "========================================"

# --- INPUT USER ---
read -p "Masukkan nama domain (misal: pkk.penajamkab.go.id): " DOMAIN
read -p "Masukkan nama user Linux (misal: pkk): " USERNAME
read -p "Masukkan port SSH baru (misal: 2110): " SSHPORT

WEBROOT="/home/$USERNAME/public_html"

echo ""
echo "=== Ringkasan Input ==="
echo "Domain       : $DOMAIN"
echo "User Linux   : $USERNAME"
echo "Web Root     : $WEBROOT"
echo "SSH Port     : $SSHPORT"
echo "========================================"
echo ""

read -p "Lanjutkan proses instalasi? (y/n): " KONFIRMASI
if [[ "$KONFIRMASI" != "y" ]]; then
    echo "Dibatalkan."
    exit 1
fi

echo "=== Updating system ==="
apt update && apt upgrade -y

echo "=== Installing SSH & setting port ==="
apt install -y openssh-server

# Backup config SSH sebelum edit
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Ganti port SSH
if grep -q "^Port " /etc/ssh/sshd_config; then
    sed -i "s/^Port .*/Port $SSHPORT/" /etc/ssh/sshd_config
else
    echo "Port $SSHPORT" >> /etc/ssh/sshd_config
fi

systemctl restart ssh

echo "=== Creating Linux user (jika belum ada) ==="
if id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME sudah ada."
else
    adduser --disabled-password --gecos "" "$USERNAME"
fi

echo "=== Installing Apache2 ==="
apt install -y apache2
a2enmod rewrite proxy_fcgi setenvif

echo "=== Creating web directory ==="
mkdir -p $WEBROOT

echo "=== Downloading maintenance page ==="
wget -O $WEBROOT/index.html https://raw.githubusercontent.com/Zerstravorsch/bg_mt/refs/heads/main/index.html

# Tambahkan phpinfo sebagai info tambahan
echo "<?php phpinfo();" > $WEBROOT/info.php

# Set owner dan permission
chown -R $USERNAME:$USERNAME /home/$USERNAME
chmod -R 755 /home/$USERNAME

echo "=== Installing PHP 8.3 ==="
apt install -y php8.3 php8.3-fpm php8.3-cli php8.3-mysql php8.3-xml php8.3-mbstring php8.3-curl php8.3-zip php8.3-gd

a2enconf php8.3-fpm

echo "=== Creating Apache VirtualHost ==="
cat > /etc/apache2/sites-available/$DOMAIN.conf <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    DocumentRoot $WEBROOT

    <Directory $WEBROOT>
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php8.3-fpm.sock|fcgi://localhost/"
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN-error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN-access.log combined
</VirtualHost>
EOF

a2ensite $DOMAIN.conf
systemctl reload apache2

echo "=== Installing MySQL Server ==="
apt install -y mysql-server

echo "========================================"
echo "         INSTALASI SELESAI"
echo "========================================"
echo "Domain       : http://$DOMAIN"
echo "Web Root     : $WEBROOT"
echo "SSH Port     : $SSHPORT"
echo "========================================"
echo ""
echo "Silakan login SSH dg perintah:"
echo "ssh -p $SSHPORT $USERNAME@IP_SERVER"
echo ""

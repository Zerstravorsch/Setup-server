#!/bin/bash

# Pastikan script dijalankan sebagai root
if [ "$EUID" -ne 0 ]; then
  echo "Harap jalankan script ini sebagai root/sudo."
  exit 1
fi

echo "========================================"
echo "   SETUP SERVER - UBUNTU 20.04.6 LTS"
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

echo "=== Updating system & installing dependencies ==="
apt update && apt upgrade -y
apt install -y software-properties-common curl ca-certificates lsb-release gnupg apt-transport-https wget

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
    echo "Silakan atur password untuk user $USERNAME:"
    passwd "$USERNAME"
fi

echo "=== Installing Apache2 (Target: 2.4.41) ==="
apt install -y apache2
a2enmod rewrite proxy_fcgi setenvif

echo "=== Installing PHP 7.4.33 & FPM ==="
# Menggunakan repository bawaan Ubuntu 20.04
apt install -y php7.4 php7.4-fpm php7.4-cli php7.4-mysql php7.4-xml php7.4-mbstring php7.4-curl php7.4-zip php7.4-gd php7.4-json php7.4-common

a2enconf php7.4-fpm

echo "=== Setup Repository & Installing MariaDB 10.4 ==="
# Import GPG Key & Tambahkan Repo MariaDB 10.4 khusus Focal
mkdir -p /etc/apt/keyrings
curl -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp'

cat <<EOF > /etc/apt/sources.list.d/mariadb.list
# MariaDB 10.4 repository list
deb [signed-by=/etc/apt/keyrings/mariadb-keyring.pgp] https://archive.mariadb.org/mariadb-10.4/repo/ubuntu focal main
EOF

apt update
apt install -y mariadb-server mariadb-client

systemctl enable mariadb
systemctl start mariadb

echo "=== Creating web directory ==="
mkdir -p $WEBROOT

echo "=== Downloading maintenance page ==="
wget -O $WEBROOT/index.html https://raw.githubusercontent.com/Zerstravorsch/bg_mt/refs/heads/main/index.html

# Tambahkan phpinfo sebagai info tambahan
echo "<?php phpinfo();" > $WEBROOT/info.php

# Set owner dan permission
chown -R $USERNAME:$USERNAME /home/$USERNAME
chmod -R 755 /home/$USERNAME

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
        SetHandler "proxy:unix:/run/php/php7.4-fpm.sock|fcgi://localhost/"
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN-error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN-access.log combined
</VirtualHost>
EOF

a2ensite $DOMAIN.conf
systemctl reload apache2

echo "========================================"
echo "         INSTALASI SELESAI"
echo "========================================"
echo "Domain       : http://$DOMAIN"
echo "Web Root     : $WEBROOT"
echo "SSH Port     : $SSHPORT"
echo "Apache Ver   : $(apache2 -v | head -n 1)"
echo "PHP Version  : $(php -v | head -n 1)"
echo "MariaDB Ver  : $(mysql --version)"
echo "========================================"
echo ""
echo "Silakan login SSH dengan perintah:"
echo "ssh -p $SSHPORT $USERNAME@IP_SERVER"
echo ""

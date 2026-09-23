```bash
#!/bin/bash

# ============================================================
# EOFFICE SERVER SETUP
#
# Target:
#   Ubuntu 20.04
#   Apache 2.4.x
#   PHP 7.4
#   PHP 7.4-FPM
#   MariaDB 10.4.x
#
# Features:
#   - Automatic validation
#   - Repository fallback
#   - Configuration backup
#   - Transactional rollback
#   - SSH validation before restart
#   - Apache validation
#   - PHP-FPM validation
#   - MariaDB validation
#
# IMPORTANT:
#   Full OS rollback is NOT possible using Bash alone.
#   Use Proxmox VM snapshot before running this script.
# ============================================================

set -Eeuo pipefail

# ============================================================
# GLOBAL VARIABLES
# ============================================================

SCRIPT_NAME="$(basename "$0")"
BACKUP_ROOT="/root/eoffice-setup-backup-$(date +%Y%m%d-%H%M%S)"

DOMAIN=""
USERNAME=""
SSHPORT=""
WEBROOT=""

ROLLBACK_NEEDED=0

ORIGINAL_SSH_CONFIG=""
ORIGINAL_SSH_PORT=""

CREATED_USER=0
CREATED_WEBROOT=0
CREATED_APACHE_SITE=0
CREATED_MARIADB_REPO=0

PHP_VERSION="7.4"
MARIADB_MAJOR="10.4"

# ============================================================
# LOGGING
# ============================================================

log() {
    echo ""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo ""
    echo "============================================================"
    echo "ERROR"
    echo "============================================================"
    echo "$*"
    echo "============================================================"
}

# ============================================================
# ROLLBACK FUNCTION
# ============================================================

rollback() {

    echo ""
    echo "============================================================"
    echo "             STARTING ROLLBACK"
    echo "============================================================"

    set +e

    # --------------------------------------------------------
    # Stop services
    # --------------------------------------------------------

    systemctl stop apache2 2>/dev/null || true
    systemctl stop php7.4-fpm 2>/dev/null || true

    # --------------------------------------------------------
    # Restore Apache site
    # --------------------------------------------------------

    if [[ -n "${DOMAIN:-}" ]]; then

        if [[ -f "$BACKUP_ROOT/apache/$DOMAIN.conf" ]]; then

            echo "Restoring Apache VirtualHost..."

            cp \
                "$BACKUP_ROOT/apache/$DOMAIN.conf" \
                "/etc/apache2/sites-available/$DOMAIN.conf"

        else

            rm -f "/etc/apache2/sites-available/$DOMAIN.conf"

        fi

        a2dissite "$DOMAIN.conf" 2>/dev/null || true

    fi

    # --------------------------------------------------------
    # Restore Apache configuration
    # --------------------------------------------------------

    if [[ -f "$BACKUP_ROOT/apache/apache2.conf" ]]; then

        cp \
            "$BACKUP_ROOT/apache/apache2.conf" \
            /etc/apache2/apache2.conf

    fi

    # --------------------------------------------------------
    # Restore SSH
    # --------------------------------------------------------

    if [[ -f "$BACKUP_ROOT/ssh/sshd_config" ]]; then

        echo "Restoring SSH configuration..."

        cp \
            "$BACKUP_ROOT/ssh/sshd_config" \
            /etc/ssh/sshd_config

    fi

    # --------------------------------------------------------
    # Restore SSH config directory
    # --------------------------------------------------------

    if [[ -d "$BACKUP_ROOT/ssh/sshd_config.d" ]]; then

        rm -rf /etc/ssh/sshd_config.d

        cp -a \
            "$BACKUP_ROOT/ssh/sshd_config.d" \
            /etc/ssh/sshd_config.d

    fi

    # --------------------------------------------------------
    # Restore webroot
    # --------------------------------------------------------

    if [[ "$CREATED_WEBROOT" -eq 1 && -n "${WEBROOT:-}" ]]; then

        if [[ -d "$BACKUP_ROOT/webroot" ]]; then

            echo "Restoring webroot..."

            rm -rf "$WEBROOT"

            mkdir -p "$(dirname "$WEBROOT")"

            cp -a \
                "$BACKUP_ROOT/webroot" \
                "$WEBROOT"

        else

            echo "Removing newly created webroot..."

            rm -rf "$WEBROOT"

        fi

    fi

    # --------------------------------------------------------
    # Remove created user
    # --------------------------------------------------------

    if [[ "$CREATED_USER" -eq 1 && -n "${USERNAME:-}" ]]; then

        echo "Removing newly created Linux user..."

        userdel -r "$USERNAME" 2>/dev/null || true

    fi

    # --------------------------------------------------------
    # Remove MariaDB repository added by script
    # --------------------------------------------------------

    if [[ "$CREATED_MARIADB_REPO" -eq 1 ]]; then

        echo "Removing MariaDB fallback repository..."

        rm -f /etc/apt/sources.list.d/mariadb-10.4.list
        rm -f /etc/apt/sources.list.d/mariadb.list

        apt update >/dev/null 2>&1 || true

    fi

    # --------------------------------------------------------
    # Restart services
    # --------------------------------------------------------

    sshd -t 2>/dev/null && systemctl restart ssh 2>/dev/null || true

    apache2ctl configtest 2>/dev/null && systemctl start apache2 2>/dev/null || true

    systemctl start php7.4-fpm 2>/dev/null || true

    echo ""
    echo "============================================================"
    echo "             ROLLBACK FINISHED"
    echo "============================================================"
    echo ""
    echo "Backup tersedia di:"
    echo "$BACKUP_ROOT"
    echo ""

}

# ============================================================
# ERROR HANDLER
# ============================================================

error_handler() {

    local EXIT_CODE=$?
    local LINE_NUMBER=$1

    error "Script gagal pada line $LINE_NUMBER dengan exit code $EXIT_CODE."

    if [[ "$ROLLBACK_NEEDED" -eq 1 ]]; then
        rollback
    fi

    exit "$EXIT_CODE"
}

trap 'error_handler $LINENO' ERR

# ============================================================
# EXIT HANDLER
# ============================================================

cleanup() {
    :
}

trap cleanup EXIT

# ============================================================
# ROOT CHECK
# ============================================================

if [[ "$EUID" -ne 0 ]]; then

    echo "ERROR: Script harus dijalankan sebagai root."

    echo ""
    echo "Gunakan:"
    echo "sudo bash $SCRIPT_NAME"

    exit 1

fi

# ============================================================
# CREATE BACKUP DIRECTORY
# ============================================================

mkdir -p "$BACKUP_ROOT"

mkdir -p "$BACKUP_ROOT/ssh"
mkdir -p "$BACKUP_ROOT/apache"
mkdir -p "$BACKUP_ROOT/webroot"
mkdir -p "$BACKUP_ROOT/apt"

ROLLBACK_NEEDED=1

# ============================================================
# CHECK OS
# ============================================================

log "Checking operating system..."

if [[ ! -f /etc/os-release ]]; then

    error "Tidak dapat mendeteksi operating system."

    exit 1

fi

source /etc/os-release

echo "OS       : $PRETTY_NAME"
echo "Version  : $VERSION_ID"

if [[ "$ID" != "ubuntu" ]]; then

    error "Script ini dibuat untuk Ubuntu."

    exit 1

fi

# ============================================================
# INPUT
# ============================================================

echo ""
echo "========================================"
echo "      SETUP SERVER EOFFICE"
echo "========================================"

read -p "Masukkan nama domain: " DOMAIN
read -p "Masukkan nama user Linux: " USERNAME
read -p "Masukkan port SSH baru: " SSHPORT

WEBROOT="/home/$USERNAME/public_html"

# Basic validation

if [[ -z "$DOMAIN" ]]; then
    error "Domain tidak boleh kosong."
    exit 1
fi

if [[ -z "$USERNAME" ]]; then
    error "Username tidak boleh kosong."
    exit 1
fi

if ! [[ "$SSHPORT" =~ ^[0-9]+$ ]]; then
    error "Port SSH harus berupa angka."
    exit 1
fi

if (( SSHPORT < 1024 || SSHPORT > 65535 )); then
    error "Port SSH harus berada antara 1024-65535."
    exit 1
fi

echo ""
echo "========================================"
echo "Ringkasan"
echo "========================================"
echo "Domain       : $DOMAIN"
echo "User         : $USERNAME"
echo "Webroot      : $WEBROOT"
echo "SSH Port     : $SSHPORT"
echo "PHP          : 7.4"
echo "MariaDB      : 10.4.x"
echo "========================================"
echo ""

read -p "Lanjutkan? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" ]]; then

    echo "Dibatalkan."

    exit 0

fi

# ============================================================
# BACKUP CURRENT CONFIGURATION
# ============================================================

log "Backing up current configuration..."

cp /etc/ssh/sshd_config \
   "$BACKUP_ROOT/ssh/sshd_config"

if [[ -d /etc/ssh/sshd_config.d ]]; then

    cp -a \
        /etc/ssh/sshd_config.d \
        "$BACKUP_ROOT/ssh/"

fi

cp /etc/apache2/apache2.conf \
   "$BACKUP_ROOT/apache/apache2.conf"

if [[ -f "/etc/apache2/sites-available/$DOMAIN.conf" ]]; then

    cp \
        "/etc/apache2/sites-available/$DOMAIN.conf" \
        "$BACKUP_ROOT/apache/$DOMAIN.conf"

fi

# Backup existing webroot

if [[ -d "$WEBROOT" ]]; then

    log "Existing webroot detected."

    cp -a \
        "$WEBROOT" \
        "$BACKUP_ROOT/webroot"

    CREATED_WEBROOT=1

else

    CREATED_WEBROOT=1

fi

# ============================================================
# APT UPDATE
# ============================================================

log "Updating APT repository..."

apt-get update

# ============================================================
# INSTALL SSH
# ============================================================

log "Installing OpenSSH..."

apt-get install -y openssh-server

systemctl enable ssh

# ============================================================
# SSH CONFIGURATION
# ============================================================

log "Configuring SSH..."

cp /etc/ssh/sshd_config \
   "$BACKUP_ROOT/ssh/sshd_config-before-change"

sed -i '/^[[:space:]]*Port[[:space:]]/d' \
    /etc/ssh/sshd_config

echo "Port $SSHPORT" >> /etc/ssh/sshd_config

# IMPORTANT:
# Validate BEFORE restarting SSH.

sshd -t

systemctl restart ssh

# ============================================================
# CREATE USER
# ============================================================

log "Creating Linux user..."

if id "$USERNAME" >/dev/null 2>&1; then

    echo "User $USERNAME already exists."

else

    adduser \
        --disabled-password \
        --gecos "" \
        "$USERNAME"

    CREATED_USER=1

fi

# ============================================================
# INSTALL APACHE
# ============================================================

log "Installing Apache..."

apt-get install -y apache2

systemctl enable apache2
systemctl start apache2

a2enmod rewrite
a2enmod proxy
a2enmod proxy_fcgi
a2enmod setenvif

# ============================================================
# CREATE WEBROOT
# ============================================================

log "Creating webroot..."

mkdir -p "$WEBROOT"

# ============================================================
# DOWNLOAD MAINTENANCE PAGE
# ============================================================

log "Downloading maintenance page..."

wget \
    -O "$WEBROOT/index.html" \
    https://raw.githubusercontent.com/Zerstravorsch/bg_mt/refs/heads/main/index.html

# ============================================================
# PHP REPOSITORY CHECK
# ============================================================

log "Checking PHP 7.4 repository..."

if apt-cache show php7.4 >/dev/null 2>&1; then

    echo "PHP 7.4 tersedia dari repository Ubuntu."

else

    echo ""
    echo "PHP 7.4 tidak tersedia dari repository Ubuntu."
    echo "Mencoba repository alternatif..."

    # --------------------------------------------------------
    # PHP repository fallback
    # --------------------------------------------------------

    apt-get install -y \
        software-properties-common \
        ca-certificates \
        lsb-release \
        apt-transport-https \
        gnupg

    # Ondrej PHP repository
    add-apt-repository -y ppa:ondrej/php

    apt-get update

    if ! apt-cache show php7.4 >/dev/null 2>&1; then

        error "PHP 7.4 tidak tersedia bahkan setelah repository fallback."

        exit 1

    fi

fi

# ============================================================
# INSTALL PHP 7.4
# ============================================================

log "Installing PHP 7.4..."

apt-get install -y \
    php7.4 \
    php7.4-cli \
    php7.4-fpm \
    php7.4-mysql \
    php7.4-xml \
    php7.4-mbstring \
    php7.4-curl \
    php7.4-zip \
    php7.4-gd \
    php7.4-bcmath \
    php7.4-soap \
    php7.4-intl \
    php7.4-readline

# ============================================================
# PHP-FPM
# ============================================================

log "Configuring PHP-FPM..."

systemctl enable php7.4-fpm
systemctl restart php7.4-fpm

if [[ ! -S /run/php/php7.4-fpm.sock ]]; then

    error "PHP 7.4-FPM socket tidak ditemukan."

    exit 1

fi

# ============================================================
# PHP TEST
# ============================================================

PHP_INSTALLED_VERSION=$(php7.4 -r 'echo PHP_VERSION;')

echo "Installed PHP: $PHP_INSTALLED_VERSION"

if [[ "$PHP_INSTALLED_VERSION" != 7.4.* ]]; then

    error "PHP version tidak sesuai. Ditemukan: $PHP_INSTALLED_VERSION"

    exit 1

fi

# ============================================================
# APACHE VIRTUALHOST
# ============================================================

log "Creating Apache VirtualHost..."

cat > "/etc/apache2/sites-available/$DOMAIN.conf" <<EOF
<VirtualHost *:80>

    ServerName $DOMAIN

    DocumentRoot $WEBROOT

    <Directory $WEBROOT>

        Options FollowSymLinks

        AllowOverride All

        Require all granted

    </Directory>

    <FilesMatch \.php$>

        SetHandler "proxy:unix:/run/php/php7.4-fpm.sock|fcgi://localhost/"

    </FilesMatch>

    DirectoryIndex index.php index.html

    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN-error.log

    CustomLog \${APACHE_LOG_DIR}/$DOMAIN-access.log combined

</VirtualHost>
EOF

CREATED_APACHE_SITE=1

a2ensite "$DOMAIN.conf"

a2dissite 000-default.conf || true

# ============================================================
# APACHE TEST
# ============================================================

log "Testing Apache configuration..."

apache2ctl configtest

systemctl reload apache2

# ============================================================
# CREATE PHP TEST
# ============================================================

cat > "$WEBROOT/info.php" <<'EOF'
<?php
phpinfo();
EOF

# ============================================================
# PERMISSIONS
# ============================================================

log "Setting permissions..."

chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

find "/home/$USERNAME" \
    -type d \
    -exec chmod 755 {} \;

find "/home/$USERNAME" \
    -type f \
    -exec chmod 644 {} \;

# ============================================================
# MARIADB REPOSITORY CHECK
# ============================================================

log "Checking MariaDB repository..."

if apt-cache show mariadb-server >/dev/null 2>&1; then

    echo "MariaDB tersedia dari
```

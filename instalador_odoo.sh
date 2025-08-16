#!/usr/bin/env bash
set -euo pipefail

yellow(){ printf '\e[33m%s\e[0m\n' "$*"; }

### ─────────────────────────────────────────────────────────────────────
### 1. Perguntas ao usuário (só três!)
### ─────────────────────────────────────────────────────────────────────
read -rp "Qual versão do Odoo? (16.0, 17.0, 18.0) [16.0]: " ODOO_VERSION
ODOO_VERSION=${ODOO_VERSION:-16.0}

read -rp "Qual domínio (FQDN)? [ex.: postos.tectonny.com.br]: " DOMAIN
while [[ -z "$DOMAIN" ]]; do
  read -rp "Domínio não pode ser vazio. Digite novamente: " DOMAIN
done

read -rp "E-mail de contato para o Certbot (Let's Encrypt): " CERT_EMAIL
while [[ -z "$CERT_EMAIL" ]]; do
  read -rp "E-mail não pode ser vazio. Digite novamente: " CERT_EMAIL
done

### ─────────────────────────────────────────────────────────────────────
### 2. Variáveis derivadas
### ─────────────────────────────────────────────────────────────────────
ODOO_HOME="/opt/odoo${ODOO_VERSION%.*}"     # 16.0 → /opt/odoo16
ODOO_USER="odoo"
ADMIN_PASSWD="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)"
WORKERS=3                                   # ajuste conforme HW
MEM_HARD=$((2*1024*1024*1024))              # 2 GB
MEM_SOFT=$((1500*1024*1024))                # 1.5 GB

yellow "⏳ Iniciando instalação do Odoo $ODOO_VERSION para o domínio $DOMAIN …"

### ─────────────────────────────────────────────────────────────────────
### 3. Pacotes base
### ─────────────────────────────────────────────────────────────────────
apt update && apt -y upgrade
apt install -y git curl wget build-essential python3-venv python3-dev \
               libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev libffi-dev \
               libjpeg-dev libpq-dev libtiff-dev libopenjp2-7 liblcms2-dev \
               nodejs npm postgresql gdebi-core nginx snapd
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot || true
timedatectl set-timezone America/Sao_Paulo

### ─────────────────────────────────────────────────────────────────────
### 4. Usuário, diretórios e PostgreSQL
### ─────────────────────────────────────────────────────────────────────
adduser --system --home="$ODOO_HOME" --group "$ODOO_USER" || true
mkdir -p "$ODOO_HOME"/{venv,extra-addons,tmp,log}
chown -R "$ODOO_USER":"$ODOO_USER" "$ODOO_HOME"
sudo -u postgres createuser -s "$ODOO_USER" || true

### ─────────────────────────────────────────────────────────────────────
### 5. Odoo core + virtualenv
### ─────────────────────────────────────────────────────────────────────
sudo -u "$ODOO_USER" git clone --depth 1 --branch "$ODOO_VERSION" \
      https://github.com/odoo/odoo.git "$ODOO_HOME/odoo"
sudo -u "$ODOO_USER" python3 -m venv "$ODOO_HOME/venv"
sudo -u "$ODOO_USER" "$ODOO_HOME/venv/bin/pip" install -U pip wheel
sudo -u "$ODOO_USER" "$ODOO_HOME/venv/bin/pip" install -r "$ODOO_HOME/odoo/requirements.txt"

### ─────────────────────────────────────────────────────────────────────
### 6. Add-ons OCA (l10n-brazil + web)
### ─────────────────────────────────────────────────────────────────────
get_addons(){
  local repo=$1
  local dest="$ODOO_HOME/tmp/$(basename "$repo")"
  sudo -u "$ODOO_USER" git clone --depth 1 --branch "$ODOO_VERSION" "$repo" "$dest"
  sudo -u "$ODOO_USER" cp -a "$dest"/* "$ODOO_HOME/extra-addons/"
  rm -rf "$dest"
}
get_addons https://github.com/OCA/l10n-brazil.git
get_addons https://github.com/OCA/web.git
sudo -u "$ODOO_USER" "$ODOO_HOME/venv/bin/pip" install \
   -r https://raw.githubusercontent.com/OCA/l10n-brazil/$ODOO_VERSION/requirements.txt \
   -r https://raw.githubusercontent.com/OCA/web/$ODOO_VERSION/requirements.txt

### ─────────────────────────────────────────────────────────────────────
### 7. wkhtmltopdf
### ─────────────────────────────────────────────────────────────────────
wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb
gdebi -n wkhtmltox_0.12.6-1.focal_amd64.deb
rm wkhtmltox_0.12.6-1.focal_amd64.deb

### ─────────────────────────────────────────────────────────────────────
### 8. odoo.conf limpo
### ─────────────────────────────────────────────────────────────────────
cat >/etc/odoo${ODOO_VERSION%.*}.conf <<EOF
[options]
admin_passwd       = $ADMIN_PASSWD
db_host            = False
db_port            = False
db_user            = $ODOO_USER
db_password        = False
addons_path        = $ODOO_HOME/odoo/addons,$ODOO_HOME/extra-addons
logfile            = $ODOO_HOME/log/odoo${ODOO_VERSION%.*}.log
proxy_mode         = True
http_port          = 8069
workers            = $WORKERS
limit_memory_hard  = $MEM_HARD
limit_memory_soft  = $MEM_SOFT
limit_time_cpu     = 600
limit_time_real    = 1200
EOF
chown "$ODOO_USER":"$ODOO_USER" /etc/odoo${ODOO_VERSION%.*}.conf
chmod 640 /etc/odoo${ODOO_VERSION%.*}.conf

### ─────────────────────────────────────────────────────────────────────
### 9. systemd unit
### ─────────────────────────────────────────────────────────────────────
cat >/etc/systemd/system/odoo${ODOO_VERSION%.*}.service <<EOF
[Unit]
Description=Odoo $ODOO_VERSION
After=postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=$ODOO_USER
Group=$ODOO_USER
ExecStart=$ODOO_HOME/venv/bin/python $ODOO_HOME/odoo/odoo-bin -c /etc/odoo${ODOO_VERSION%.*}.conf
Restart=on-failure
TimeoutStopSec=60s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now odoo${ODOO_VERSION%.*}

### ─────────────────────────────────────────────────────────────────────
### 10. Nginx vhost + Certbot (100 % não-interativo)
### ─────────────────────────────────────────────────────────────────────
cat >/etc/nginx/sites-available/odoo <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass         http://127.0.0.1:8069;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 720s;
    }
}
EOF
ln -sf /etc/nginx/sites-available/odoo /etc/nginx/sites-enabled/odoo
nginx -t && systemctl reload nginx

certbot --nginx -d "$DOMAIN" --redirect \
        --agree-tos --no-eff-email -m "$CERT_EMAIL" --non-interactive

yellow "✅ Instalação concluída!"
yellow "→ Backend: http://127.0.0.1:8069"
yellow "→ Domínio : https://$DOMAIN"
yellow "→ Senha master (admin_passwd) = $ADMIN_PASSWD"

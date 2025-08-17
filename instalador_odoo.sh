#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "\e[31m❌  Erro na linha $LINENO →  $BASH_COMMAND\e[0m"' ERR

yellow(){ printf '\e[33m%s\e[0m\n' "$*"; }

###############################################################################
# 1. Perguntas ao usuário
###############################################################################
read -rp "Qual versão do Odoo? (16.0, 17.0, 18.0) [16.0]: " ODOO_VERSION
ODOO_VERSION=${ODOO_VERSION:-16.0}

read -rp "Qual domínio (FQDN)? [ex.: postos.tectonny.com.br]: " DOMAIN
while [[ -z $DOMAIN ]]; do read -rp "Domínio não pode ser vazio: " DOMAIN; done

read -rp "E-mail de contacto p/ Certbot: " CERT_EMAIL
while [[ -z $CERT_EMAIL ]]; do read -rp "E-mail não pode ser vazio: " CERT_EMAIL; done

###############################################################################
# 2. Constantes
###############################################################################
BRANCH=$ODOO_VERSION
ODOO_HOME="/opt/odoo${ODOO_VERSION%.*}"
ODOO_USER=odoo
ADMIN_PASSWD=$(openssl rand -base64 12 | tr -dc A-Za-z0-9 | head -c16)
WORKERS=3
MEM_HARD=$((2*1024*1024*1024))   # 2 GB
MEM_SOFT=$((1500*1024*1024))     # 1,5 GB
CONF=/etc/odoo${ODOO_VERSION%.*}.conf
SERVICE=/etc/systemd/system/odoo${ODOO_VERSION%.*}.service

yellow "⏳ Instalando Odoo $ODOO_VERSION em $DOMAIN …"

###############################################################################
# 3. Pacotes base
###############################################################################
apt update
apt -y upgrade
DEBIAN_FRONTEND=noninteractive apt install -y \
  git curl wget build-essential python3-venv python3-dev \
  libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev libffi-dev \
  libjpeg-dev libpq-dev libtiff-dev libopenjp2-7 liblcms2-dev \
  nodejs npm postgresql nginx snapd

snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot
timedatectl set-timezone America/Sao_Paulo

###############################################################################
# 4. Usuário, pastas e PostgreSQL
###############################################################################
id "$ODOO_USER" &>/dev/null || adduser --system --home "$ODOO_HOME" --group "$ODOO_USER"
mkdir -p "$ODOO_HOME"/{venv,extra-addons,tmp,log}
chown -R "$ODOO_USER:$ODOO_USER" "$ODOO_HOME"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$ODOO_USER'" | grep -q 1 ||
  sudo -u postgres createuser -s "$ODOO_USER"

###############################################################################
# 5. Odoo core + venv
###############################################################################
if [[ ! -d $ODOO_HOME/odoo ]]; then
  sudo -u "$ODOO_USER" git clone --depth 1 --branch "$BRANCH" \
       https://github.com/odoo/odoo.git "$ODOO_HOME/odoo"
fi

sudo -u "$ODOO_USER" python3 -m venv "$ODOO_HOME/venv"
sudo -u "$ODOO_USER" "$ODOO_HOME/venv/bin/pip" install -U pip wheel
sudo -u "$ODOO_USER" "$ODOO_HOME/venv/bin/pip" install \
       -r "$ODOO_HOME/odoo/requirements.txt"

###############################################################################
# 6. Add-ons OCA (l10n-brazil + web) — só se o branch existir
###############################################################################
get_addons() {
  local repo="$1"
  local name=$(basename "$repo" .git)
  if git ls-remote --heads "$repo" "$BRANCH" | grep -q "$BRANCH"; then
     yellow "→ Baixando $name ($BRANCH)"
     local dst="$ODOO_HOME/tmp/$name"
     sudo -u "$ODOO_USER" git clone --depth 1 --branch "$BRANCH" "$repo" "$dst"
     sudo -u "$ODOO_USER" cp -a "$dst"/* "$ODOO_HOME/extra-addons/"
     rm -rf "$dst"
     # requirements.txt (se houver)
     if curl -fsL "https://raw.githubusercontent.com/OCA/${name#OCA\/}/$BRANCH/requirements.txt" -o /tmp/req.txt; then
        sudo -u "$ODOO_USER" "$ODOO_HOME/venv/bin/pip" install -r /tmp/req.txt
        rm -f /tmp/req.txt
     fi
  else
     yellow "→ $name não possui branch $BRANCH — ignorado."
  fi
}
get_addons https://github.com/OCA/l10n-brazil.git
get_addons https://github.com/OCA/web.git

###############################################################################
# 7. wkhtmltopdf (jammy → fallback focal)
###############################################################################
if ! command -v wkhtmltopdf &>/dev/null; then
  WKHTML_VER=0.12.6-1
  for SUFFIX in jammy focal; do
     DEB="wkhtmltox_${WKHTML_VER}.${SUFFIX}_amd64.deb"
     URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTML_VER}/${DEB}"
     if wget -q "$URL" -O "/tmp/$DEB"; then
        apt install -y "/tmp/$DEB" && rm -f "/tmp/$DEB" && break
     fi
  done
fi

###############################################################################
# 8. odoo.conf
###############################################################################
cat >"$CONF" <<EOF
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
chown "$ODOO_USER:$ODOO_USER" "$CONF"
chmod 640 "$CONF"

###############################################################################
# 9. systemd unit
###############################################################################
cat >"$SERVICE" <<EOF
[Unit]
Description=Odoo $ODOO_VERSION
After=postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=$ODOO_USER
Group=$ODOO_USER
ExecStart=$ODOO_HOME/venv/bin/python $ODOO_HOME/odoo/odoo-bin -c $CONF
Restart=on-failure
TimeoutStopSec=60s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$(basename "$SERVICE")"

###############################################################################
# 10. Nginx + HTTPS
###############################################################################
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
nginx -t
systemctl reload nginx

certbot --nginx -d "$DOMAIN" --redirect \
        --agree-tos --no-eff-email -m "$CERT_EMAIL" --non-interactive

###############################################################################
# 11. Fim
###############################################################################
yellow "✅ Instalação concluída!"
yellow "→ Backend local : http://127.0.0.1:8069"
yellow "→ Domínio       : https://$DOMAIN"
yellow "→ Senha master  : $ADMIN_PASSWD"

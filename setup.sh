#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  FiveM Server Manager — Debian 12 Bookworm
#  Nginx · MariaDB · phpMyAdmin · FiveM Artifacts (Recommended Stable)
#  Multi-Instanz · UFW · Screen-Konsole · fuser Pre-Cleanup
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Farben ────────────────────────────────────────────────────────────────────
R='\033[0;31m'   G='\033[0;32m'   Y='\033[1;33m'
C='\033[0;36m'   B='\033[1;34m'   M='\033[0;35m'
W='\033[1;37m'   D='\033[0;90m'   N='\033[0m'

# ── Pfade ─────────────────────────────────────────────────────────────────────
CONFIG_DIR="/etc/fivem-manager"
CONFIG_FILE="${CONFIG_DIR}/manager.conf"
SERVERS_DIR="/opt/fivem/servers"
ARTIFACTS_DIR="/opt/fivem/artifacts"
FIVEM_USER="fivem"
LOG_DIR="/var/log/fivem-manager"

# ── FiveM Artifacts API ──────────────────────────────────────────────────────
VERSIONS_API="https://changelogs-live.fivem.net/api/changelog/versions/linux/server"

# ═══════════════════════════════════════════════════════════════════════════════
#  Hilfsfunktionen
# ═══════════════════════════════════════════════════════════════════════════════

log_info()    { echo -e "${C}[INFO]${N}  $1"; }
log_ok()      { echo -e "${G}[OK]${N}    $1"; }
log_warn()    { echo -e "${Y}[WARN]${N}  $1"; }
log_error()   { echo -e "${R}[ERROR]${N} $1"; }
log_step()    { echo -e "${B}[STEP]${N}  ${W}$1${N}"; }
separator()   { echo -e "${D}────────────────────────────────────────────────────────────${N}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Dieses Script muss als root ausgeführt werden."
        exit 1
    fi
}

banner() {
    clear
    echo -e "${B}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║           FiveM Server Manager · Debian 12              ║"
    echo "  ║     Nginx · MariaDB · phpMyAdmin · Multi-Instanz        ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${N}"
}

confirm() {
    local prompt="$1"
    local answer
    echo -en "${Y}${prompt} [j/N]: ${N}"
    if [[ -c /dev/tty ]]; then
        read -r answer </dev/tty
    else
        read -r answer
    fi
    [[ "$answer" =~ ^[jJyY]$ ]]
}

read_input() {
    local prompt="$1"
    local default="${2:-}"
    local result
    if [[ -n "$default" ]]; then
        echo -en "${C}${prompt} [${default}]: ${N}" >&2
    else
        echo -en "${C}${prompt}: ${N}" >&2
    fi
    if [[ -c /dev/tty ]]; then
        read -r result </dev/tty
    else
        read -r result
    fi
    echo "${result:-$default}"
}

# Konfiguration laden / initialisieren
init_config() {
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<EOF
# FiveM Manager Konfiguration
# Automatisch generiert — $(date)
INSTALLED=0
FIVEM_USER=${FIVEM_USER}
SERVERS_DIR=${SERVERS_DIR}
ARTIFACTS_DIR=${ARTIFACTS_DIR}
ARTIFACT_BUILD=
ARTIFACT_URL=
SERVER_COUNT=0
EOF
    fi
    source "$CONFIG_FILE"
}

save_config_var() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$CONFIG_FILE"
    else
        echo "${key}=${val}" >> "$CONFIG_FILE"
    fi
}

# Server-Konfigurationsdatei
get_server_conf() {
    echo "${CONFIG_DIR}/server_${1}.conf"
}

save_server_conf() {
    local name="$1" tcp_port="$2" udp_port="$3" txadmin_port="$4" rcon_pass="$5"
    local conf
    conf=$(get_server_conf "$name")
    cat > "$conf" <<EOF
SERVER_NAME=${name}
TCP_PORT=${tcp_port}
UDP_PORT=${udp_port}
TXADMIN_PORT=${txadmin_port}
RCON_PASSWORD=${rcon_pass}
CREATED=$(date +%Y-%m-%d_%H:%M:%S)
EOF
}

list_server_names() {
    local servers=()
    for conf in "${CONFIG_DIR}"/server_*.conf; do
        [[ -f "$conf" ]] || continue
        local name
        name=$(grep '^SERVER_NAME=' "$conf" | cut -d= -f2)
        servers+=("$name")
    done
    echo "${servers[@]}"
}

count_servers() {
    local count=0
    for conf in "${CONFIG_DIR}"/server_*.conf; do
        [[ -f "$conf" ]] && ((count++))
    done
    echo "$count"
}

gen_password() {
    tr -dc 'A-Za-z0-9!@#$%' < /dev/urandom | head -c 24
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Installation
# ═══════════════════════════════════════════════════════════════════════════════

install_dependencies() {
    log_step "System-Pakete aktualisieren & Abhängigkeiten installieren..."
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y \
        curl wget git unzip xz-utils screen htop \
        ufw psmisc net-tools lsof \
        software-properties-common apt-transport-https \
        ca-certificates gnupg jq \
        libatomic1 libc6
    log_ok "Abhängigkeiten installiert."
}

install_nginx() {
    log_step "Nginx installieren..."

    # Konfliktbehebung: Apache2 stoppen und entfernen (wird von PHP-Paketen auf Debian oft nachinstalliert)
    systemctl stop apache2 2>/dev/null || true
    systemctl disable apache2 2>/dev/null || true
    apt-get purge -y apache2 apache2-utils apache2-bin 2>/dev/null || true

    apt-get install -y nginx

    # Port-Konflikte aufräumen
    rm -f /etc/nginx/sites-enabled/default

    systemctl enable nginx
    systemctl restart nginx
    log_ok "Nginx installiert und gestartet."
}

install_mariadb() {
    log_step "MariaDB installieren..."
    apt-get install -y mariadb-server mariadb-client

    systemctl enable mariadb
    systemctl start mariadb

    log_info "MariaDB für Remote-Zugriff konfigurieren..."

    # Bind auf alle Interfaces
    local mariadb_conf="/etc/mysql/mariadb.conf.d/50-server.cnf"
    if [[ -f "$mariadb_conf" ]]; then
        sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' "$mariadb_conf"
    fi

    systemctl restart mariadb
    log_ok "MariaDB installiert — Remote-Zugriff aktiv (0.0.0.0)."
}

setup_mariadb_user() {
    local db_user="$1" db_pass="$2"

    log_step "MariaDB Benutzer '${db_user}' einrichten (Zugriff von überall)..."

    mysql -u root <<EOSQL
CREATE USER IF NOT EXISTS '${db_user}'@'%' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON *.* TO '${db_user}'@'%' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON *.* TO '${db_user}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOSQL

    log_ok "MariaDB Benutzer '${db_user}' erstellt — Zugriff von überall."
}

install_phpmyadmin() {
    log_step "phpMyAdmin installieren..."

    local pma_dir="/usr/share/phpmyadmin"
    local pma_version="5.2.2"
    local pma_url="https://files.phpmyadmin.net/phpMyAdmin/${pma_version}/phpMyAdmin-${pma_version}-all-languages.tar.gz"

    # Apache2 sicherheitshalber erneut stoppen & säubern
    systemctl stop apache2 2>/dev/null || true
    systemctl disable apache2 2>/dev/null || true
    apt-get purge -y apache2 apache2-utils apache2-bin 2>/dev/null || true

    # PHP installieren
    apt-get install -y php-fpm php-mysql php-mbstring php-zip php-gd php-json php-curl php-xml

    # PHP-FPM Version ermitteln
    local php_ver
    php_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    local php_sock="/run/php/php${php_ver}-fpm.sock"

    systemctl enable "php${php_ver}-fpm" 2>/dev/null || true
    systemctl restart "php${php_ver}-fpm" 2>/dev/null || true

    # phpMyAdmin herunterladen
    if [[ ! -d "$pma_dir" ]]; then
        cd /tmp
        wget -q "$pma_url" -O phpmyadmin.tar.gz
        tar xzf phpmyadmin.tar.gz
        mv "phpMyAdmin-${pma_version}-all-languages" "$pma_dir"
        rm -f phpmyadmin.tar.gz

        # Blowfish Secret generieren
        local blowfish
        blowfish=$(gen_password)
        cp "${pma_dir}/config.sample.inc.php" "${pma_dir}/config.inc.php"
        sed -i "s|\$cfg\['blowfish_secret'\] = ''|\$cfg['blowfish_secret'] = '${blowfish}'|" "${pma_dir}/config.inc.php"

        # Temp-Verzeichnis
        mkdir -p "${pma_dir}/tmp"
        chown -R www-data:www-data "$pma_dir"
    fi

    # Nginx Server-Block für phpMyAdmin
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    cat > /etc/nginx/sites-available/phpmyadmin <<EONGINX
server {
    listen 8080;
    listen [::]:8080;
    server_name _;
    root ${pma_dir};
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${php_sock};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EONGINX

    ln -sf /etc/nginx/sites-available/phpmyadmin /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default

    nginx -t && systemctl restart nginx
    log_ok "phpMyAdmin installiert — erreichbar auf Port 8080."
}

download_fivem_artifacts() {
    log_step "FiveM Artifacts (Recommended Stable) herunterladen..."

    # API abfragen
    local api_response
    api_response=$(curl -s "$VERSIONS_API")

    local build_num download_url
    build_num=$(echo "$api_response" | jq -r '.recommended')
    download_url=$(echo "$api_response" | jq -r '.recommended_download')

    if [[ -z "$build_num" || "$build_num" == "null" ]]; then
        log_error "Konnte FiveM Artifacts-Version nicht ermitteln."
        return 1
    fi

    log_info "Recommended Build: ${build_num}"
    log_info "Download: ${download_url}"

    mkdir -p "$ARTIFACTS_DIR"

    # Herunterladen und entpacken
    cd /tmp
    wget -q --show-progress "$download_url" -O fx.tar.xz
    tar xf fx.tar.xz -C "$ARTIFACTS_DIR"
    rm -f fx.tar.xz

    # Ausführbar machen
    chmod +x "${ARTIFACTS_DIR}/run.sh" 2>/dev/null || true
    find "$ARTIFACTS_DIR" -name "FXServer" -exec chmod +x {} \; 2>/dev/null || true

    save_config_var "ARTIFACT_BUILD" "$build_num"
    save_config_var "ARTIFACT_URL" "$download_url"

    log_ok "FiveM Artifacts Build ${build_num} installiert in ${ARTIFACTS_DIR}."
}

create_system_user() {
    local username="$1" password="$2"

    log_step "System-Benutzer '${username}' erstellen..."

    if id "$username" &>/dev/null; then
        log_warn "Benutzer '${username}' existiert bereits."
    else
        useradd -m -s /bin/bash -d "/home/${username}" "$username"
        echo "${username}:${password}" | chpasswd
        usermod -aG sudo "$username" 2>/dev/null || true
        log_ok "Benutzer '${username}' erstellt."
    fi

    # Verzeichnisstruktur
    mkdir -p "$SERVERS_DIR" "$ARTIFACTS_DIR"
    chown -R "${username}:${username}" /opt/fivem
}

setup_firewall() {
    log_step "UFW Firewall einrichten..."

    ufw --force enable
    ufw default deny incoming
    ufw default allow outgoing

    # Standard-Ports
    ufw allow 22/tcp     comment 'SSH'
    ufw allow 80/tcp     comment 'HTTP'
    ufw allow 443/tcp    comment 'HTTPS'
    ufw allow 8080/tcp   comment 'phpMyAdmin'
    ufw allow 3306/tcp   comment 'MariaDB'

    ufw reload
    log_ok "Firewall Grundkonfiguration aktiv."
}

open_server_ports() {
    local name="$1" tcp_port="$2" udp_port="$3" txadmin_port="$4"

    log_info "Firewall-Ports öffnen für Server '${name}'..."

    ufw allow "${tcp_port}/tcp"  comment "FiveM ${name} TCP"
    ufw allow "${udp_port}/udp"  comment "FiveM ${name} UDP"
    ufw allow "${txadmin_port}/tcp" comment "txAdmin ${name}"

    ufw reload
    log_ok "Ports ${tcp_port}/tcp, ${udp_port}/udp, ${txadmin_port}/tcp geöffnet."
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Server erstellen
# ═══════════════════════════════════════════════════════════════════════════════

create_server() {
    local name tcp_port udp_port txadmin_port rcon_pass server_dir

    separator
    echo -e "${W}Neuen FiveM Server erstellen${N}"
    separator

    name=$(read_input "Server-Name (ohne Leerzeichen)" "server1")
    name=$(echo "$name" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')

    # Prüfen ob Server existiert
    if [[ -f "$(get_server_conf "$name")" ]]; then
        log_error "Server '${name}' existiert bereits!"
        return 1
    fi

    tcp_port=$(read_input "Game TCP Port" "30120")
    udp_port=$(read_input "Game UDP Port" "${tcp_port}")
    txadmin_port=$(read_input "txAdmin Web-Port" "40120")
    rcon_pass=$(read_input "RCON Passwort" "$(gen_password)")

    server_dir="${SERVERS_DIR}/${name}"

    log_step "Server '${name}' einrichten..."

    # Verzeichnisstruktur
    mkdir -p "${server_dir}/resources" "${server_dir}/cache" "${server_dir}/data"

    # server.cfg generieren
    cat > "${server_dir}/server.cfg" <<EOCFG
# ═══════════════════════════════════════════════════════════════
# FiveM Server Konfiguration — ${name}
# Generiert: $(date)
# ═══════════════════════════════════════════════════════════════

# ── Netzwerk ──────────────────────────────────────────────────
endpoint_add_tcp "0.0.0.0:${tcp_port}"
endpoint_add_udp "0.0.0.0:${udp_port}"

# ── Server-Info ───────────────────────────────────────────────
sv_hostname "${name} — FiveM Server"
sv_maxclients 48
sets sv_projectName "${name}"
sets sv_projectDesc "FiveM Server managed by FiveM Server Manager"
sets locale "de-DE"
sets tags "default"

# ── RCON ──────────────────────────────────────────────────────
rcon_password "${rcon_pass}"

# ── Sicherheit ────────────────────────────────────────────────
sv_endpointprivacy true
sv_scriptHookAllowed 0

# ── Lizenz ────────────────────────────────────────────────────
# Trage deinen cfx.re Lizenzschlüssel hier ein:
# sv_licenseKey "DEIN_LIZENZ_KEY"

# ── Steam Web API (optional) ─────────────────────────────────
# set steam_webApiKey "DEIN_STEAM_API_KEY"

# ── Ressourcen ────────────────────────────────────────────────
ensure mapmanager
ensure chat
ensure spawnmanager
ensure sessionmanager
ensure basic-gamemode
ensure hardcap
ensure rconlog

# ── OneSync ───────────────────────────────────────────────────
set onesync on

# ── Datenbank (oxmysql) ──────────────────────────────────────
# set mysql_connection_string "mysql://user:password@localhost/database?charset=utf8mb4"
EOCFG

    # Start-Script pro Server
    cat > "${server_dir}/start.sh" <<EOSTART
#!/bin/bash
cd "${server_dir}"
exec ${ARTIFACTS_DIR}/run.sh +exec server.cfg
EOSTART
    chmod +x "${server_dir}/start.sh"

    # Systemd Service erstellen
    cat > "/etc/systemd/system/fivem-${name}.service" <<EOSERVICE
[Unit]
Description=FiveM Server — ${name}
After=network.target mariadb.service
Wants=network-online.target

[Service]
Type=forking
User=${FIVEM_USER}
Group=${FIVEM_USER}
WorkingDirectory=${server_dir}
ExecStartPre=/bin/bash -c 'fuser -k ${tcp_port}/tcp ${udp_port}/udp 2>/dev/null || true'
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/screen -dmS fivem-${name} ${server_dir}/start.sh
ExecStop=/usr/bin/screen -S fivem-${name} -X quit
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOSERVICE

    systemctl daemon-reload
    systemctl enable "fivem-${name}.service"

    # Eigentümer setzen
    chown -R "${FIVEM_USER}:${FIVEM_USER}" "${server_dir}"

    # Firewall-Ports öffnen
    open_server_ports "$name" "$tcp_port" "$udp_port" "$txadmin_port"

    # Server-Konfiguration speichern
    save_server_conf "$name" "$tcp_port" "$udp_port" "$txadmin_port" "$rcon_pass"

    # Zähler aktualisieren
    local count
    count=$(count_servers)
    save_config_var "SERVER_COUNT" "$count"

    separator
    log_ok "Server '${name}' erstellt!"
    echo -e "  ${D}Verzeichnis:${N}    ${server_dir}"
    echo -e "  ${D}Game Port:${N}      ${tcp_port}/tcp, ${udp_port}/udp"
    echo -e "  ${D}txAdmin Port:${N}   ${txadmin_port}"
    echo -e "  ${D}RCON Passwort:${N}  ${rcon_pass}"
    echo -e "  ${D}Service:${N}        fivem-${name}.service"
    echo -e "  ${D}Screen:${N}         screen -r fivem-${name}"
    separator
}

create_multiple_servers() {
    local count
    count=$(read_input "Wie viele Server sollen erstellt werden?" "1")

    if ! [[ "$count" =~ ^[0-9]+$ ]] || [[ "$count" -lt 1 ]]; then
        log_error "Ungültige Anzahl."
        return 1
    fi

    local base_port
    base_port=$(read_input "Basis-Game-Port (wird pro Server um 1 erhöht)" "30120")
    local base_txport
    base_txport=$(read_input "Basis-txAdmin-Port (wird pro Server um 1 erhöht)" "40120")

    for ((i=1; i<=count; i++)); do
        local srv_name="server${i}"
        local srv_tcp=$((base_port + i - 1))
        local srv_udp=$srv_tcp
        local srv_txadmin=$((base_txport + i - 1))
        local srv_rcon
        srv_rcon=$(gen_password)

        # Prüfen ob schon existiert — Name inkrementieren
        while [[ -f "$(get_server_conf "$srv_name")" ]]; do
            local num
            num=$(echo "$srv_name" | grep -oP '\d+$')
            num=$((num + 1))
            srv_name="server${num}"
        done

        local server_dir="${SERVERS_DIR}/${srv_name}"

        log_step "Server ${i}/${count}: '${srv_name}' (Port ${srv_tcp})..."

        mkdir -p "${server_dir}/resources" "${server_dir}/cache" "${server_dir}/data"

        cat > "${server_dir}/server.cfg" <<EOCFG
endpoint_add_tcp "0.0.0.0:${srv_tcp}"
endpoint_add_udp "0.0.0.0:${srv_udp}"
sv_hostname "${srv_name} — FiveM Server"
sv_maxclients 48
sets sv_projectName "${srv_name}"
sets sv_projectDesc "FiveM Server managed by FiveM Server Manager"
sets locale "de-DE"
sets tags "default"
rcon_password "${srv_rcon}"
sv_endpointprivacy true
sv_scriptHookAllowed 0
# sv_licenseKey "DEIN_LIZENZ_KEY"
ensure mapmanager
ensure chat
ensure spawnmanager
ensure sessionmanager
ensure basic-gamemode
ensure hardcap
ensure rconlog
set onesync on
EOCFG

        cat > "${server_dir}/start.sh" <<EOSTART
#!/bin/bash
cd "${server_dir}"
exec ${ARTIFACTS_DIR}/run.sh +exec server.cfg
EOSTART
        chmod +x "${server_dir}/start.sh"

        cat > "/etc/systemd/system/fivem-${srv_name}.service" <<EOSERVICE
[Unit]
Description=FiveM Server — ${srv_name}
After=network.target mariadb.service
Wants=network-online.target

[Service]
Type=forking
User=${FIVEM_USER}
Group=${FIVEM_USER}
WorkingDirectory=${server_dir}
ExecStartPre=/bin/bash -c 'fuser -k ${srv_tcp}/tcp ${srv_udp}/udp 2>/dev/null || true'
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/screen -dmS fivem-${srv_name} ${server_dir}/start.sh
ExecStop=/usr/bin/screen -S fivem-${srv_name} -X quit
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOSERVICE

        chown -R "${FIVEM_USER}:${FIVEM_USER}" "${server_dir}"
        open_server_ports "$srv_name" "$srv_tcp" "$srv_udp" "$srv_txadmin"
        save_server_conf "$srv_name" "$srv_tcp" "$srv_udp" "$srv_txadmin" "$srv_rcon"
    done

    systemctl daemon-reload

    local total
    total=$(count_servers)
    save_config_var "SERVER_COUNT" "$total"

    log_ok "${count} Server erstellt. Gesamt: ${total} Server."
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Server-Verwaltung
# ═══════════════════════════════════════════════════════════════════════════════

kill_port_processes() {
    local port="$1"
    log_info "Prozesse auf Port ${port} beenden (fuser)..."
    fuser -k "${port}/tcp" 2>/dev/null || true
    fuser -k "${port}/udp" 2>/dev/null || true
    sleep 1
}

start_server() {
    local name="$1"
    local conf
    conf=$(get_server_conf "$name")

    if [[ ! -f "$conf" ]]; then
        log_error "Server '${name}' nicht gefunden."
        return 1
    fi

    source "$conf"

    log_step "Server '${name}' starten..."

    # Prozesse auf den Ports killen via fuser
    kill_port_processes "$TCP_PORT"
    if [[ "$TCP_PORT" != "$UDP_PORT" ]]; then
        kill_port_processes "$UDP_PORT"
    fi

    # Screen-Session prüfen
    if screen -ls | grep -q "fivem-${name}"; then
        log_warn "Screen-Session 'fivem-${name}' läuft bereits. Stoppe zuerst..."
        screen -S "fivem-${name}" -X quit 2>/dev/null || true
        sleep 2
    fi

    # Via systemd starten
    systemctl start "fivem-${name}.service"
    sleep 3

    if screen -ls | grep -q "fivem-${name}"; then
        log_ok "Server '${name}' gestartet. (Port ${TCP_PORT})"
    else
        log_error "Server '${name}' konnte nicht gestartet werden. Prüfe Logs."
    fi
}

stop_server() {
    local name="$1"
    local conf
    conf=$(get_server_conf "$name")

    if [[ ! -f "$conf" ]]; then
        log_error "Server '${name}' nicht gefunden."
        return 1
    fi

    log_step "Server '${name}' stoppen..."

    # Screen-Session beenden
    if screen -ls | grep -q "fivem-${name}"; then
        screen -S "fivem-${name}" -X quit 2>/dev/null || true
    fi

    systemctl stop "fivem-${name}.service" 2>/dev/null || true

    source "$conf"
    kill_port_processes "$TCP_PORT"

    log_ok "Server '${name}' gestoppt."
}

restart_server() {
    local name="$1"
    log_step "Server '${name}' neustarten..."
    stop_server "$name"
    sleep 3
    start_server "$name"
}

server_console() {
    local name="$1"

    if ! screen -ls | grep -q "fivem-${name}"; then
        log_error "Server '${name}' läuft nicht — keine Konsole verfügbar."
        return 1
    fi

    echo ""
    log_info "Verbinde mit Konsole von '${name}'..."
    echo -e "${Y}Zum Verlassen: ${W}STRG+A${Y} dann ${W}D${Y} (Detach)${N}"
    echo ""
    sleep 2
    screen -r "fivem-${name}"
}

server_status() {
    local name="$1"
    local conf
    conf=$(get_server_conf "$name")

    if [[ ! -f "$conf" ]]; then
        log_error "Server '${name}' nicht gefunden."
        return 1
    fi

    source "$conf"

    local status_screen="GESTOPPT"
    local status_service="inactive"
    local status_color="$R"

    if screen -ls | grep -q "fivem-${name}"; then
        status_screen="LÄUFT"
        status_color="$G"
    fi

    status_service=$(systemctl is-active "fivem-${name}.service" 2>/dev/null || echo "inactive")

    echo -e "  ${W}${name}${N}"
    echo -e "    Status:     ${status_color}${status_screen}${N} (systemd: ${status_service})"
    echo -e "    Game Port:  ${TCP_PORT}/tcp, ${UDP_PORT}/udp"
    echo -e "    txAdmin:    ${TXADMIN_PORT}"
    echo -e "    RCON:       ${RCON_PASSWORD}"
    echo -e "    Verzeichnis: ${SERVERS_DIR}/${name}"
}

start_all_servers() {
    log_step "Alle Server starten..."
    for name in $(list_server_names); do
        start_server "$name"
    done
}

stop_all_servers() {
    log_step "Alle Server stoppen..."
    for name in $(list_server_names); do
        stop_server "$name"
    done
}

restart_all_servers() {
    log_step "Alle Server neustarten..."
    for name in $(list_server_names); do
        restart_server "$name"
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Server löschen
# ═══════════════════════════════════════════════════════════════════════════════

delete_server() {
    local name="$1"
    local conf
    conf=$(get_server_conf "$name")

    if [[ ! -f "$conf" ]]; then
        log_error "Server '${name}' nicht gefunden."
        return 1
    fi

    if ! confirm "Server '${name}' wirklich löschen? (Daten werden entfernt)"; then
        log_info "Abgebrochen."
        return 0
    fi

    source "$conf"

    # Stoppen
    stop_server "$name"

    # Firewall-Regeln entfernen
    ufw delete allow "${TCP_PORT}/tcp" 2>/dev/null || true
    ufw delete allow "${UDP_PORT}/udp" 2>/dev/null || true
    ufw delete allow "${TXADMIN_PORT}/tcp" 2>/dev/null || true

    # Systemd-Service entfernen
    systemctl disable "fivem-${name}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/fivem-${name}.service"
    systemctl daemon-reload

    # Daten löschen
    rm -rf "${SERVERS_DIR}/${name}"
    rm -f "$conf"

    local count
    count=$(count_servers)
    save_config_var "SERVER_COUNT" "$count"

    log_ok "Server '${name}' vollständig gelöscht."
}

# ═══════════════════════════════════════════════════════════════════════════════
#  FiveM Artifacts Update
# ═══════════════════════════════════════════════════════════════════════════════

update_artifacts() {
    log_step "FiveM Artifacts auf neueste Recommended-Version aktualisieren..."

    local api_response build_num download_url
    api_response=$(curl -s "$VERSIONS_API")
    build_num=$(echo "$api_response" | jq -r '.recommended')
    download_url=$(echo "$api_response" | jq -r '.recommended_download')

    source "$CONFIG_FILE"

    if [[ "$ARTIFACT_BUILD" == "$build_num" ]]; then
        log_ok "Bereits auf dem neuesten Recommended Build: ${build_num}"
        return 0
    fi

    log_info "Aktueller Build: ${ARTIFACT_BUILD:-unbekannt}"
    log_info "Neuer Build:     ${build_num}"

    if ! confirm "Update durchführen?"; then
        return 0
    fi

    # Alle Server stoppen
    stop_all_servers

    # Backup
    if [[ -d "$ARTIFACTS_DIR" ]]; then
        mv "$ARTIFACTS_DIR" "${ARTIFACTS_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
    fi

    mkdir -p "$ARTIFACTS_DIR"

    cd /tmp
    wget -q --show-progress "$download_url" -O fx.tar.xz
    tar xf fx.tar.xz -C "$ARTIFACTS_DIR"
    rm -f fx.tar.xz

    chmod +x "${ARTIFACTS_DIR}/run.sh" 2>/dev/null || true
    find "$ARTIFACTS_DIR" -name "FXServer" -exec chmod +x {} \; 2>/dev/null || true
    chown -R "${FIVEM_USER}:${FIVEM_USER}" "$ARTIFACTS_DIR"

    save_config_var "ARTIFACT_BUILD" "$build_num"
    save_config_var "ARTIFACT_URL" "$download_url"

    log_ok "Artifacts auf Build ${build_num} aktualisiert."

    if confirm "Alle Server jetzt neu starten?"; then
        start_all_servers
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MariaDB Datenbank für Server erstellen
# ═══════════════════════════════════════════════════════════════════════════════

create_database() {
    local db_name db_user db_pass

    db_name=$(read_input "Datenbank-Name" "")
    db_user=$(read_input "Datenbank-Benutzer" "")
    db_pass=$(read_input "Datenbank-Passwort" "$(gen_password)")

    if [[ -z "$db_name" || -z "$db_user" ]]; then
        log_error "Name und Benutzer dürfen nicht leer sein."
        return 1
    fi

    mysql -u root <<EOSQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'%' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'%';
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
EOSQL

    separator
    log_ok "Datenbank erstellt!"
    echo -e "  ${D}Datenbank:${N} ${db_name}"
    echo -e "  ${D}Benutzer:${N}  ${db_user}"
    echo -e "  ${D}Passwort:${N}  ${db_pass}"
    echo -e "  ${D}Connection String:${N}"
    echo -e "  ${W}mysql://${db_user}:${db_pass}@localhost/${db_name}?charset=utf8mb4${N}"
    separator
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Menüsystem
# ═══════════════════════════════════════════════════════════════════════════════

select_server() {
    local servers
    servers=($(list_server_names))

    if [[ ${#servers[@]} -eq 0 ]]; then
        log_warn "Keine Server vorhanden."
        return 1
    fi

    echo ""
    echo -e "${W}Verfügbare Server:${N}"
    local i=1
    for srv in "${servers[@]}"; do
        local running="${R}⬤ GESTOPPT${N}"
        if screen -ls 2>/dev/null | grep -q "fivem-${srv}"; then
            running="${G}⬤ LÄUFT${N}"
        fi
        echo -e "  ${C}${i})${N} ${srv}  ${running}"
        ((i++))
    done
    echo ""

    local choice
    choice=$(read_input "Server-Nummer wählen" "1")

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt ${#servers[@]} ]]; then
        log_error "Ungültige Auswahl."
        return 1
    fi

    SELECTED_SERVER="${servers[$((choice-1))]}"
    return 0
}

menu_manage_server() {
    while true; do
        if ! select_server; then
            return
        fi

        local name="$SELECTED_SERVER"
        separator
        server_status "$name"
        separator

        echo ""
        echo -e "  ${C}1)${N} Starten"
        echo -e "  ${C}2)${N} Stoppen"
        echo -e "  ${C}3)${N} Neustarten"
        echo -e "  ${C}4)${N} Live-Konsole"
        echo -e "  ${C}5)${N} Status"
        echo -e "  ${C}6)${N} server.cfg bearbeiten"
        echo -e "  ${C}7)${N} Server löschen"
        echo -e "  ${C}0)${N} Zurück"
        echo ""

        local action
        action=$(read_input "Aktion" "0")

        case "$action" in
            1) start_server "$name" ;;
            2) stop_server "$name" ;;
            3) restart_server "$name" ;;
            4) server_console "$name" ;;
            5) server_status "$name" ;;
            6)
                local editor="${EDITOR:-nano}"
                "$editor" "${SERVERS_DIR}/${name}/server.cfg"
                log_ok "server.cfg gespeichert. Neustart nötig für Änderungen."
                ;;
            7)
                delete_server "$name"
                return
                ;;
            0) return ;;
            *) log_error "Ungültige Eingabe." ;;
        esac

        echo ""
        echo -en "${D}Weiter mit Enter...${N}"
        if [[ -c /dev/tty ]]; then read -r </dev/tty; else read -r; fi
    done
}

menu_show_all() {
    separator
    echo -e "${W}Alle Server:${N}"
    separator

    local servers
    servers=($(list_server_names))

    if [[ ${#servers[@]} -eq 0 ]]; then
        log_warn "Keine Server vorhanden."
        return
    fi

    for srv in "${servers[@]}"; do
        server_status "$srv"
        echo ""
    done

    separator
}

menu_mass_action() {
    echo ""
    echo -e "  ${C}1)${N} Alle Server starten"
    echo -e "  ${C}2)${N} Alle Server stoppen"
    echo -e "  ${C}3)${N} Alle Server neustarten"
    echo -e "  ${C}0)${N} Zurück"
    echo ""

    local choice
    choice=$(read_input "Aktion" "0")

    case "$choice" in
        1) start_all_servers ;;
        2) stop_all_servers ;;
        3) restart_all_servers ;;
        0) return ;;
        *) log_error "Ungültige Eingabe." ;;
    esac
}

menu_database() {
    echo ""
    echo -e "  ${C}1)${N} Neue Datenbank + Benutzer erstellen"
    echo -e "  ${C}2)${N} Alle Datenbanken anzeigen"
    echo -e "  ${C}3)${N} MariaDB Status"
    echo -e "  ${C}0)${N} Zurück"
    echo ""

    local choice
    choice=$(read_input "Aktion" "0")

    case "$choice" in
        1) create_database ;;
        2) mysql -u root -e "SHOW DATABASES;" ;;
        3) systemctl status mariadb --no-pager ;;
        0) return ;;
        *) log_error "Ungültige Eingabe." ;;
    esac
}

menu_firewall() {
    echo ""
    echo -e "  ${C}1)${N} Firewall Status anzeigen"
    echo -e "  ${C}2)${N} Alle Regeln anzeigen"
    echo -e "  ${C}3)${N} Port manuell öffnen"
    echo -e "  ${C}4)${N} Port manuell schließen"
    echo -e "  ${C}0)${N} Zurück"
    echo ""

    local choice
    choice=$(read_input "Aktion" "0")

    case "$choice" in
        1) ufw status verbose ;;
        2) ufw status numbered ;;
        3)
            local port protocol
            port=$(read_input "Port" "")
            protocol=$(read_input "Protokoll (tcp/udp/both)" "both")
            if [[ -n "$port" ]]; then
                if [[ "$protocol" == "both" ]]; then
                    ufw allow "${port}/tcp"
                    ufw allow "${port}/udp"
                else
                    ufw allow "${port}/${protocol}"
                fi
                ufw reload
                log_ok "Port ${port}/${protocol} geöffnet."
            fi
            ;;
        4)
            local port protocol
            port=$(read_input "Port" "")
            protocol=$(read_input "Protokoll (tcp/udp/both)" "both")
            if [[ -n "$port" ]]; then
                if [[ "$protocol" == "both" ]]; then
                    ufw delete allow "${port}/tcp" 2>/dev/null || true
                    ufw delete allow "${port}/udp" 2>/dev/null || true
                else
                    ufw delete allow "${port}/${protocol}" 2>/dev/null || true
                fi
                ufw reload
                log_ok "Port ${port}/${protocol} geschlossen."
            fi
            ;;
        0) return ;;
        *) log_error "Ungültige Eingabe." ;;
    esac
}

menu_extras() {
    echo ""
    echo -e "  ${C}1)${N} FiveM Artifacts aktualisieren"
    echo -e "  ${C}2)${N} Nginx Status / Neustart"
    echo -e "  ${C}3)${N} MariaDB Status / Neustart"
    echo -e "  ${C}4)${N} System-Info"
    echo -e "  ${C}5)${N} Alle Screen-Sessions anzeigen"
    echo -e "  ${C}0)${N} Zurück"
    echo ""

    local choice
    choice=$(read_input "Aktion" "0")

    case "$choice" in
        1) update_artifacts ;;
        2)
            systemctl status nginx --no-pager
            if confirm "Nginx neustarten?"; then
                systemctl restart nginx
                log_ok "Nginx neugestartet."
            fi
            ;;
        3)
            systemctl status mariadb --no-pager
            if confirm "MariaDB neustarten?"; then
                systemctl restart mariadb
                log_ok "MariaDB neugestartet."
            fi
            ;;
        4)
            echo ""
            echo -e "  ${D}Hostname:${N}     $(hostname)"
            echo -e "  ${D}IP:${N}           $(hostname -I | awk '{print $1}')"
            echo -e "  ${D}Kernel:${N}       $(uname -r)"
            echo -e "  ${D}Uptime:${N}       $(uptime -p)"
            echo -e "  ${D}RAM:${N}          $(free -h | awk '/Mem:/{print $3"/"$2}')"
            echo -e "  ${D}Disk:${N}         $(df -h / | awk 'NR==2{print $3"/"$2" ("$5" belegt)"}')"
            echo -e "  ${D}FiveM Build:${N}  $(grep '^ARTIFACT_BUILD=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)"
            echo -e "  ${D}Server:${N}       $(count_servers) konfiguriert"
            echo ""
            ;;
        5) screen -ls ;;
        0) return ;;
        *) log_error "Ungültige Eingabe." ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Erstinstallation
# ═══════════════════════════════════════════════════════════════════════════════

initial_setup() {
    banner
    echo -e "${W}Erstinstallation starten${N}"
    separator

    # Benutzer-Eingaben sammeln
    local sys_user sys_pass db_user db_pass server_count base_port base_txport

    sys_user=$(read_input "System-Benutzername für FiveM" "$FIVEM_USER")
    sys_pass=$(read_input "System-Passwort" "$(gen_password)")
    db_user=$(read_input "MariaDB Admin-Benutzername" "fivem_admin")
    db_pass=$(read_input "MariaDB Admin-Passwort" "$(gen_password)")
    server_count=$(read_input "Anzahl FiveM-Server" "1")
    base_port=$(read_input "Basis-Game-Port" "30120")
    base_txport=$(read_input "Basis-txAdmin-Port" "40120")

    FIVEM_USER="$sys_user"
    save_config_var "FIVEM_USER" "$FIVEM_USER"

    separator
    echo -e "${W}Zusammenfassung:${N}"
    echo -e "  ${D}System-User:${N}     ${sys_user}"
    echo -e "  ${D}System-Passwort:${N} ${sys_pass}"
    echo -e "  ${D}DB-User:${N}         ${db_user}"
    echo -e "  ${D}DB-Passwort:${N}     ${db_pass}"
    echo -e "  ${D}Server:${N}          ${server_count}"
    echo -e "  ${D}Ports:${N}           ${base_port}+ / txAdmin: ${base_txport}+"
    separator

    if ! confirm "Installation starten?"; then
        log_info "Abgebrochen."
        exit 0
    fi

    echo ""
    log_step "Installation wird durchgeführt..."
    echo ""

    # 1. Abhängigkeiten
    install_dependencies

    # 2. System-Benutzer
    create_system_user "$sys_user" "$sys_pass"

    # 3. Nginx
    install_nginx

    # 4. MariaDB
    install_mariadb
    setup_mariadb_user "$db_user" "$db_pass"

    # 5. phpMyAdmin
    install_phpmyadmin

    # 6. FiveM Artifacts
    download_fivem_artifacts

    # 7. Firewall
    setup_firewall

    # 8. Server erstellen
    for ((i=1; i<=server_count; i++)); do
        local srv_name="server${i}"
        local srv_tcp=$((base_port + i - 1))
        local srv_udp=$srv_tcp
        local srv_txadmin=$((base_txport + i - 1))
        local srv_rcon
        srv_rcon=$(gen_password)
        local server_dir="${SERVERS_DIR}/${srv_name}"

        log_step "Server ${i}/${server_count}: '${srv_name}' (Port ${srv_tcp})..."

        mkdir -p "${server_dir}/resources" "${server_dir}/cache" "${server_dir}/data"

        cat > "${server_dir}/server.cfg" <<EOCFG
endpoint_add_tcp "0.0.0.0:${srv_tcp}"
endpoint_add_udp "0.0.0.0:${srv_udp}"
sv_hostname "${srv_name} — FiveM Server"
sv_maxclients 48
sets sv_projectName "${srv_name}"
sets sv_projectDesc "FiveM Server managed by FiveM Server Manager"
sets locale "de-DE"
sets tags "default"
rcon_password "${srv_rcon}"
sv_endpointprivacy true
sv_scriptHookAllowed 0
# sv_licenseKey "DEIN_LIZENZ_KEY"
ensure mapmanager
ensure chat
ensure spawnmanager
ensure sessionmanager
ensure basic-gamemode
ensure hardcap
ensure rconlog
set onesync on
EOCFG

        cat > "${server_dir}/start.sh" <<EOSTART
#!/bin/bash
cd "${server_dir}"
exec ${ARTIFACTS_DIR}/run.sh +exec server.cfg
EOSTART
        chmod +x "${server_dir}/start.sh"

        cat > "/etc/systemd/system/fivem-${srv_name}.service" <<EOSERVICE
[Unit]
Description=FiveM Server — ${srv_name}
After=network.target mariadb.service
Wants=network-online.target

[Service]
Type=forking
User=${FIVEM_USER}
Group=${FIVEM_USER}
WorkingDirectory=${server_dir}
ExecStartPre=/bin/bash -c 'fuser -k ${srv_tcp}/tcp ${srv_udp}/udp 2>/dev/null || true'
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/screen -dmS fivem-${srv_name} ${server_dir}/start.sh
ExecStop=/usr/bin/screen -S fivem-${srv_name} -X quit
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOSERVICE

        chown -R "${FIVEM_USER}:${FIVEM_USER}" "${server_dir}"
        open_server_ports "$srv_name" "$srv_tcp" "$srv_udp" "$srv_txadmin"
        save_server_conf "$srv_name" "$srv_tcp" "$srv_udp" "$srv_txadmin" "$srv_rcon"
    done

    systemctl daemon-reload
    save_config_var "INSTALLED" "1"
    save_config_var "SERVER_COUNT" "$server_count"

    # Zusammenfassung
    banner
    echo -e "${G}═══════════════════════════════════════════════════════════${N}"
    echo -e "${G}  Installation abgeschlossen!${N}"
    echo -e "${G}═══════════════════════════════════════════════════════════${N}"
    echo ""
    echo -e "  ${W}System-Benutzer:${N}  ${sys_user} / ${sys_pass}"
    echo -e "  ${W}MariaDB:${N}          ${db_user} / ${db_pass}"
    echo -e "  ${W}phpMyAdmin:${N}       http://$(hostname -I | awk '{print $1}'):8080"
    echo -e "  ${W}FiveM Build:${N}      $(grep '^ARTIFACT_BUILD=' "$CONFIG_FILE" | cut -d= -f2)"
    echo ""
    echo -e "  ${W}Server:${N}"
    for ((i=1; i<=server_count; i++)); do
        local srv_name="server${i}"
        source "$(get_server_conf "$srv_name")"
        echo -e "    ${C}${srv_name}${N} — Port ${TCP_PORT}, txAdmin ${TXADMIN_PORT}, RCON: ${RCON_PASSWORD}"
    done
    echo ""
    echo -e "  ${W}Befehle:${N}"
    echo -e "    ${D}Starten:${N}     systemctl start fivem-<name>"
    echo -e "    ${D}Stoppen:${N}     systemctl stop fivem-<name>"
    echo -e "    ${D}Neustarten:${N}  systemctl restart fivem-<name>"
    echo -e "    ${D}Konsole:${N}     screen -r fivem-<name>"
    echo -e "    ${D}Manager:${N}     bash $(readlink -f "$0")"
    echo ""
    separator

    echo ""
    if confirm "Server jetzt starten?"; then
        start_all_servers
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Hauptmenü
# ═══════════════════════════════════════════════════════════════════════════════

main_menu() {
    while true; do
        banner
        source "$CONFIG_FILE" 2>/dev/null || true

        local srv_count
        srv_count=$(count_servers)

        echo -e "  ${D}FiveM Build:${N}  ${ARTIFACT_BUILD:-nicht installiert}"
        echo -e "  ${D}Server:${N}       ${srv_count} konfiguriert"
        echo -e "  ${D}Benutzer:${N}     ${FIVEM_USER}"
        echo ""
        separator
        echo ""
        echo -e "  ${C}1)${N}  ${W}Einzelnen Server verwalten${N}      (Start/Stop/Konsole/...)"
        echo -e "  ${C}2)${N}  ${W}Alle Server anzeigen${N}"
        echo -e "  ${C}3)${N}  ${W}Masse-Aktion${N}                    (Alle starten/stoppen)"
        echo -e "  ${C}4)${N}  ${W}Neuen Server erstellen${N}"
        echo -e "  ${C}5)${N}  ${W}Mehrere Server auf einmal erstellen${N}"
        echo ""
        separator
        echo ""
        echo -e "  ${C}6)${N}  ${W}Datenbank verwalten${N}"
        echo -e "  ${C}7)${N}  ${W}Firewall verwalten${N}"
        echo -e "  ${C}8)${N}  ${W}Extras${N}                          (Update/Nginx/System)"
        echo ""
        separator
        echo ""
        echo -e "  ${C}9)${N}  ${W}Erstinstallation${N}                (Nginx/MariaDB/phpMyAdmin/FiveM)"
        echo -e "  ${C}0)${N}  ${W}Beenden${N}"
        echo ""

        local choice
        choice=$(read_input "Auswahl" "0")

        case "$choice" in
            1) menu_manage_server ;;
            2) menu_show_all ;;
            3) menu_mass_action ;;
            4) create_server ;;
            5) create_multiple_servers ;;
            6) menu_database ;;
            7) menu_firewall ;;
            8) menu_extras ;;
            9) initial_setup ;;
            0)
                echo ""
                log_info "Beendet."
                exit 0
                ;;
            *) log_error "Ungültige Eingabe." ;;
        esac

        echo ""
        echo -en "${D}Weiter mit Enter...${N}"
        if [[ -c /dev/tty ]]; then read -r </dev/tty; else read -r; fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Einstiegspunkt
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    check_root
    init_config

    # Wenn als Argument ein Befehl übergeben wird — Direktmodus
    case "${1:-}" in
        install)
            initial_setup
            ;;
        start)
            if [[ -n "${2:-}" ]]; then
                start_server "$2"
            else
                start_all_servers
            fi
            ;;
        stop)
            if [[ -n "${2:-}" ]]; then
                stop_server "$2"
            else
                stop_all_servers
            fi
            ;;
        restart)
            if [[ -n "${2:-}" ]]; then
                restart_server "$2"
            else
                restart_all_servers
            fi
            ;;
        console)
            if [[ -n "${2:-}" ]]; then
                server_console "$2"
            else
                log_error "Benutzung: $0 console <servername>"
            fi
            ;;
        status)
            if [[ -n "${2:-}" ]]; then
                server_status "$2"
            else
                menu_show_all
            fi
            ;;
        create)
            create_server
            ;;
        delete)
            if [[ -n "${2:-}" ]]; then
                delete_server "$2"
            else
                log_error "Benutzung: $0 delete <servername>"
            fi
            ;;
        update)
            update_artifacts
            ;;
        help|--help|-h)
            echo ""
            echo "Benutzung: $0 [befehl] [servername]"
            echo ""
            echo "Befehle:"
            echo "  install              Erstinstallation"
            echo "  start [name]         Server starten (alle wenn kein Name)"
            echo "  stop [name]          Server stoppen (alle wenn kein Name)"
            echo "  restart [name]       Server neustarten (alle wenn kein Name)"
            echo "  console <name>       Live-Konsole öffnen"
            echo "  status [name]        Status anzeigen"
            echo "  create               Neuen Server erstellen"
            echo "  delete <name>        Server löschen"
            echo "  update               FiveM Artifacts aktualisieren"
            echo "  help                 Diese Hilfe"
            echo ""
            echo "Ohne Argumente wird das interaktive Menü gestartet."
            echo ""
            ;;
        "")
            main_menu
            ;;
        *)
            log_error "Unbekannter Befehl: $1"
            echo "Nutze '$0 help' für Hilfe."
            exit 1
            ;;
    esac
}

main "$@"

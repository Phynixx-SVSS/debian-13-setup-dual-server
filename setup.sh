#!/bin/bash

# Farben & Style
red="\e[0;91m"
green="\e[0;92m"
blue="\e[0;94m"
yellow="\e[0;93m"
cyan="\e[0;96m"
bold="\e[1m"
reset="\e[0m"

# Root-Check
if [ "$EUID" -ne 0 ]; then
    echo -e "${red}Bitte führe das Skript als root aus!${reset}"
    exit 1
fi

status(){
    echo -e "${green}${bold}>>> $@...${reset}"
    sleep 1
}

runCommand(){
    COMMAND=$1
    if [[ -n "$2" ]]; then
        status "$2"
    fi

    eval "$COMMAND"
    BASH_CODE=$?
    if [ $BASH_CODE -ne 0 ]; then
        echo -e "${red}Fehler aufgetreten:${reset} ${COMMAND} lieferte Code ${BASH_CODE}"
        exit ${BASH_CODE}
    fi
}

# --- INTERAKTIVE KONFIGURATION ---

clear
echo -e "${blue}${bold}====================================================${reset}"
echo -e "${cyan}${bold}   FiveM Multi-Server Setup Wizard (Debian 12)     ${reset}"
echo -e "${blue}${bold}====================================================${reset}"
echo ""

# 1. SSH Port Konfiguration
read -r -p "$(echo -e "${yellow}SSH-Port auf diesem Server [Standard: 22]: ${reset}")" SSH_PORT
SSH_PORT=${SSH_PORT:-22}

# 2. MariaDB Konfiguration
echo -e "\n${cyan}${bold}--- MariaDB / Datenbank Konfiguration ---${reset}"
read -r -p "$(echo -e "${yellow}MariaDB installieren & konfigurieren? (y/n) [Standard: y]: ${reset}")" INSTALL_MARIADB
INSTALL_MARIADB=${INSTALL_MARIADB:-y}

DB_ACCESS_CHOICE="1"
DB_USER=""
DB_PASS=""
ALLOWED_DB_IP=""

if [[ "$INSTALL_MARIADB" =~ ^[Yy]$ ]]; then
    echo -e "\n${bold}Wähle den MariaDB Zugriffsmodus:${reset}"
    echo -e "  ${cyan}1)${reset} Nur Lokal (127.0.0.1)"
    echo -e "  ${cyan}2)${reset} Extern erreichbar (Alle IPs - 0.0.0.0 / %)"
    echo -e "  ${cyan}3)${reset} Extern erreichbar (Nur bestimmte IP-Adresse)"
    read -r -p "$(echo -e "${yellow}Auswahl [1-3] [Standard: 1]: ${reset}")" DB_ACCESS_CHOICE
    DB_ACCESS_CHOICE=${DB_ACCESS_CHOICE:-1}

    if [ "$DB_ACCESS_CHOICE" != "1" ]; then
        read -r -p "$(echo -e "${yellow}Name für den externen DB-Benutzer [Standard: external_admin]: ${reset}")" DB_USER
        DB_USER=${DB_USER:-external_admin}
        
        while [ -z "$DB_PASS" ]; do
            read -r -p "$(echo -e "${yellow}Passwort für DB-Benutzer '$DB_USER': ${reset}")" DB_PASS
            if [ -z "$DB_PASS" ]; then
                echo -e "${red}Passwort darf nicht leer sein!${reset}"
            fi
        done

        if [ "$DB_ACCESS_CHOICE" == "3" ]; then
            while [ -z "$ALLOWED_DB_IP" ]; do
                read -r -p "$(echo -e "${yellow}Erlaubte externe IP-Adresse: ${reset}")" ALLOWED_DB_IP
            done
        fi
    fi
fi

# 3. FiveM Server Konfiguration
echo -e "\n${cyan}${bold}--- FiveM Server Konfiguration ---${reset}"
read -r -p "$(echo -e "${yellow}Wie viele FiveM-Server sollen eingerichtet werden? [Standard: 2]: ${reset}")" SERVER_COUNT
SERVER_COUNT=${SERVER_COUNT:-2}

if ! [[ "$SERVER_COUNT" =~ ^[0-9]+$ ]] || [ "$SERVER_COUNT" -lt 1 ]; then
    echo -e "${red}Ungültige Serveranzahl! Abgebrochen.${reset}"
    exit 1
fi

declare -a SERVER_NAMES
declare -a TXADMIN_PORTS
declare -a GAME_PORTS
declare -a DB_NAMES

BASE_TXADMIN_PORT=40120
BASE_GAME_PORT=30120

for ((i=1; i<=SERVER_COUNT; i++)); do
    echo -e "\n${bold}--- Konfiguration Server #$i ---${reset}"
    
    DEFAULT_NAME="server$i"
    read -r -p "$(echo -e "${yellow}Server Name [Standard: $DEFAULT_NAME]: ${reset}")" S_NAME
    S_NAME=${S_NAME:-$DEFAULT_NAME}
    # Bereinigen von Leerzeichen / Sonderzeichen für Dateinamen
    S_NAME=$(echo "$S_NAME" | sed 's/[^a-zA-Z0-9_-]/_/g')
    SERVER_NAMES+=("$S_NAME")

    DEFAULT_TX=$((BASE_TXADMIN_PORT + i - 1))
    read -r -p "$(echo -e "${yellow}txAdmin Port [Standard: $DEFAULT_TX]: ${reset}")" S_TX_PORT
    S_TX_PORT=${S_TX_PORT:-$DEFAULT_TX}
    TXADMIN_PORTS+=("$S_TX_PORT")

    DEFAULT_GAME=$((BASE_GAME_PORT + (i - 1) * 5))
    read -r -p "$(echo -e "${yellow}Game Port (TCP & UDP) [Standard: $DEFAULT_GAME]: ${reset}")" S_GAME_PORT
    S_GAME_PORT=${S_GAME_PORT:-$DEFAULT_GAME}
    GAME_PORTS+=("$S_GAME_PORT")

    DEFAULT_DB="${S_NAME}_db"
    read -r -p "$(echo -e "${yellow}Datenbank Name [Standard: $DEFAULT_DB]: ${reset}")" S_DB_NAME
    S_DB_NAME=${S_DB_NAME:-$DEFAULT_DB}
    DB_NAMES+=("$S_DB_NAME")
done

# Zusammenfassung bestätigen
clear
echo -e "${green}${bold}=== SETUP ZUSAMMENFASSUNG (Debian 12 Bookworm) ===${reset}"
echo -e "SSH Port: ${cyan}$SSH_PORT${reset}"
echo -e "MariaDB: ${cyan}$INSTALL_MARIADB${reset} (Modus: $DB_ACCESS_CHOICE)"
if [ "$DB_ACCESS_CHOICE" != "1" ] && [[ "$INSTALL_MARIADB" =~ ^[Yy]$ ]]; then
    echo -e "  DB User: ${cyan}$DB_USER${reset}"
    echo -e "  Erlaubte IP: ${cyan}${ALLOWED_DB_IP:-Alle IPs (%)}${reset}"
fi
echo -e "Server Anzahl: ${cyan}$SERVER_COUNT${reset}"
for ((i=0; i<SERVER_COUNT; i++)); do
    echo -e "  - Server: ${cyan}${SERVER_NAMES[$i]}${reset} | txAdmin Port: ${cyan}${TXADMIN_PORTS[$i]}${reset} | Game Port: ${cyan}${GAME_PORTS[$i]}${reset} | DB: ${cyan}${DB_NAMES[$i]}${reset}"
done
echo ""
read -r -p "$(echo -e "${yellow}Setup jetzt ausführen? (y/n) [Standard: y]: ${reset}")" CONFIRM
CONFIRM=${CONFIRM:-y}

if ! [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${red}Installation abgebrochen.${reset}"
    exit 0
fi

# --- EXECUTION ---

# 1. Pakete installieren für Debian 12
install_packages(){
    runCommand "apt update -y && apt upgrade -y" "System wird aktualisiert"
    runCommand "apt install -y curl git screen xz-utils libssl-dev mariadb-server ufw jq lsof wget" "Debian 12 Pakete werden installiert"
}

# 2. MariaDB einrichten (Debian 12 kompatibel)
setup_mariadb_execution(){
    if ! [[ "$INSTALL_MARIADB" =~ ^[Yy]$ ]]; then
        return
    fi

    status "MariaDB für Debian 12 konfigurieren"
    
    # Pfad-Prüfung für MariaDB Config unter Debian 12
    CONF_FILES=("/etc/mysql/mariadb.conf.d/50-server.cnf" "/etc/mysql/my.cnf")
    for CONF_FILE in "${CONF_FILES[@]}"; do
        if [ -f "$CONF_FILE" ]; then
            if [ "$DB_ACCESS_CHOICE" == "1" ]; then
                sed -i -E 's/^\s*#?\s*bind-address\s*=.*/bind-address = 127.0.0.1/' "$CONF_FILE"
            else
                sed -i -E 's/^\s*#?\s*bind-address\s*=.*/bind-address = 0.0.0.0/' "$CONF_FILE"
            fi
        fi
    done
    runCommand "systemctl restart mariadb"

    # Benutzer und Datenbanken erstellen
    if [ "$DB_ACCESS_CHOICE" != "1" ]; then
        ESCAPED_DB_PASS=$(printf '%s' "$DB_PASS" | sed "s/'/''/g")
        HOST_SPEC="%"
        if [ "$DB_ACCESS_CHOICE" == "3" ]; then
            HOST_SPEC="$ALLOWED_DB_IP"
        fi

        mariadb -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'${HOST_SPEC}' IDENTIFIED BY '${ESCAPED_DB_PASS}';"
        mariadb -e "GRANT ALL PRIVILEGES ON *.* TO '${DB_USER}'@'${HOST_SPEC}' WITH GRANT OPTION;"
    fi

    for db in "${DB_NAMES[@]}"; do
        mariadb -e "CREATE DATABASE IF NOT EXISTS \`${db}\`;"
    done

    mariadb -e "FLUSH PRIVILEGES;"
}

# 3. FiveM Server & Skripte erstellen
setup_fivem_execution(){
    status "Ordnerstruktur wird angelegt"
    id -u fivem &>/dev/null || useradd -r -m -d /home/fivem -s /bin/bash fivem

    runCommand "mkdir -p /home/fivem/artifacts"
    runCommand "mkdir -p /home/fivem/scripts"

    # Artefakte herunterladen
    status "Lade neueste FiveM-Artefakte herunter"
    cd /home/fivem/artifacts || exit 1
    
    LATEST_LINK=$(curl -s https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/ | grep -oP 'href="\./\K[0-9]+-[a-f0-9]+/fx\.tar\.xz' | tail -n 1)
    
    if [ -z "$LATEST_LINK" ]; then
        echo -e "${red}Fehler: Konnte keine FiveM Artefakte finden.${reset}"
        exit 1
    fi

    runCommand "wget -q https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/$LATEST_LINK -O fx.tar.xz" "Artefakt-Download"
    runCommand "tar -xf fx.tar.xz && rm fx.tar.xz" "Entpacken der Artefakte"

    # Master-Skripte vorbereiten
    cat << 'EOF' > /home/fivem/start_all.sh
#!/bin/bash
EOF
    cat << 'EOF' > /home/fivem/stop_all.sh
#!/bin/bash
EOF
    chmod +x /home/fivem/start_all.sh /home/fivem/stop_all.sh

    # Server-Ordner und spezifische start/stop Skripte erzeugen
    for ((i=0; i<SERVER_COUNT; i++)); do
        S_NAME="${SERVER_NAMES[$i]}"
        TX_PORT="${TXADMIN_PORTS[$i]}"

        S_DIR="/home/fivem/${S_NAME}"
        runCommand "mkdir -p ${S_DIR}/data"

        START_SCRIPT="${S_DIR}/start_${S_NAME}.sh"
        STOP_SCRIPT="${S_DIR}/stop_${S_NAME}.sh"
        RESTART_SCRIPT="${S_DIR}/restart_${S_NAME}.sh"

        # Start Skript
        cat << EOF > "$START_SCRIPT"
#!/bin/bash
if screen -list | grep -q "\.${S_NAME}\s"; then
    echo "Server '${S_NAME}' läuft bereits!"
    exit 1
fi
echo "Starte FiveM Server '${S_NAME}' auf txAdmin Port ${TX_PORT}..."
cd ${S_DIR}/data || exit 1
screen -dmS ${S_NAME} /home/fivem/artifacts/run.sh +set txAdminPort ${TX_PORT} +set txAdminServerProfile ${S_NAME}
echo "Server '${S_NAME}' gestartet in Screen-Session '${S_NAME}'."
EOF

        # Stop Skript
        cat << EOF > "$STOP_SCRIPT"
#!/bin/bash
if ! screen -list | grep -q "\.${S_NAME}\s"; then
    echo "Server '${S_NAME}' läuft nicht."
    exit 1
fi
echo "Stoppe FiveM Server '${S_NAME}'..."
screen -S ${S_NAME} -X stuff $'\003'
sleep 2
screen -X -S ${S_NAME} quit 2>/dev/null
echo "Server '${S_NAME}' gestoppt."
EOF

        # Restart Skript
        cat << EOF > "$RESTART_SCRIPT"
#!/bin/bash
${STOP_SCRIPT}
sleep 2
${START_SCRIPT}
EOF

        chmod +x "$START_SCRIPT" "$STOP_SCRIPT" "$RESTART_SCRIPT"

        # Symlinks im Root-Verzeichnis für direkten Zugriff
        ln -sf "$START_SCRIPT" "/home/fivem/start_${S_NAME}.sh"
        ln -sf "$STOP_SCRIPT" "/home/fivem/stop_${S_NAME}.sh"
        ln -sf "$RESTART_SCRIPT" "/home/fivem/restart_${S_NAME}.sh"

        # Zu start_all / stop_all hinzufügen
        echo "/home/fivem/${S_NAME}/start_${S_NAME}.sh" >> /home/fivem/start_all.sh
        echo "/home/fivem/${S_NAME}/stop_${S_NAME}.sh" >> /home/fivem/stop_all.sh
    done

    # Status Skript
    cat << 'EOF' > /home/fivem/status.sh
#!/bin/bash
echo "=== Aktive FiveM Screen Sessions ==="
screen -list | grep -E "server[0-9]+" || echo "Keine aktiven Server-Sessions gefunden."
EOF
    chmod +x /home/fivem/status.sh

    chown -R fivem:fivem /home/fivem
}

# 4. Firewall einrichten
setup_firewall_execution(){
    status "Konfiguriere UFW Firewall"
    
    # SSH Port
    ufw allow ${SSH_PORT}/tcp comment 'SSH Port' > /dev/null

    # MariaDB
    if [[ "$INSTALL_MARIADB" =~ ^[Yy]$ ]]; then
        if [ "$DB_ACCESS_CHOICE" == "2" ]; then
            ufw allow 3306/tcp comment 'MariaDB Global' > /dev/null
        elif [ "$DB_ACCESS_CHOICE" == "3" ]; then
            ufw allow from ${ALLOWED_DB_IP} to any port 3306 proto tcp comment 'MariaDB Restricted' > /dev/null
        fi
    fi

    # Server Ports
    for ((i=0; i<SERVER_COUNT; i++)); do
        S_NAME="${SERVER_NAMES[$i]}"
        TX_PORT="${TXADMIN_PORTS[$i]}"
        G_PORT="${GAME_PORTS[$i]}"

        ufw allow ${TX_PORT}/tcp comment "txAdmin ${S_NAME}" > /dev/null
        ufw allow ${G_PORT}/tcp comment "FiveM Game TCP ${S_NAME}" > /dev/null
        ufw allow ${G_PORT}/udp comment "FiveM Game UDP ${S_NAME}" > /dev/null
    done

    echo "y" | ufw enable > /dev/null
}

# Ablauf starten
install_packages
setup_mariadb_execution
setup_fivem_execution
setup_firewall_execution

IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || hostname -I | awk '{print $1}')

clear
echo -e "${green}${bold}====================================================${reset}"
echo -e "${green}${bold}  SETUP FÜR DEBIAN 12 ERFOLGREICH ABGESCHLOSSEN!   ${reset}"
echo -e "${green}${bold}====================================================${reset}"
echo ""
if [[ "$INSTALL_MARIADB" =~ ^[Yy]$ ]]; then
    echo -e "${bold}MariaDB Info:${reset}"
    echo -e "  Host: ${blue}${IP}${reset} (Port 3306)"
    if [ "$DB_ACCESS_CHOICE" != "1" ]; then
        echo -e "  User: ${blue}${DB_USER}${reset}"
        echo -e "  Erlaubter Host: ${blue}${ALLOWED_DB_IP:-% (Alle IPs)}${reset}"
    else
        echo -e "  Modus: ${blue}Rein Lokal (127.0.0.1)${reset}"
    fi
    echo ""
fi

echo -e "${bold}Eingerichtete FiveM Server ($SERVER_COUNT):${reset}"
for ((i=0; i<SERVER_COUNT; i++)); do
    S_NAME="${SERVER_NAMES[$i]}"
    TX_PORT="${TXADMIN_PORTS[$i]}"
    G_PORT="${GAME_PORTS[$i]}"
    DB_NAME="${DB_NAMES[$i]}"

    echo -e "${cyan}${bold}[ ${S_NAME} ]${reset}"
    echo -e "  Starten:   ${yellow}su - fivem -c '/home/fivem/start_${S_NAME}.sh'${reset}"
    echo -e "  Stoppen:   ${yellow}su - fivem -c '/home/fivem/stop_${S_NAME}.sh'${reset}"
    echo -e "  Neustart:  ${yellow}su - fivem -c '/home/fivem/restart_${S_NAME}.sh'${reset}"
    echo -e "  txAdmin:   ${blue}http://${IP}:${TX_PORT}${reset}"
    echo -e "  Game Port: ${blue}${G_PORT} (TCP/UDP)${reset}"
    echo -e "  Datenbank: ${blue}${DB_NAME}${reset}"
    echo ""
done

echo -e "${bold}Globale Befehle:${reset}"
echo -e "  Alle starten: ${yellow}su - fivem -c '/home/fivem/start_all.sh'${reset}"
echo -e "  Alle stoppen: ${yellow}su - fivem -c '/home/fivem/stop_all.sh'${reset}"
echo -e "  Status:       ${yellow}su - fivem -c '/home/fivem/status.sh'${reset}"
echo -e "${green}${bold}====================================================${reset}"
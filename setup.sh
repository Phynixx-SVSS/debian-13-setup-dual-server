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

get_server_ip(){
    ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || hostname -I | awk '{print $1}'
}

# --- HELPER: SERVER HINZUFÜGEN ---
add_single_server(){
    S_NAME=$1
    TX_PORT=$2
    GAME_PORT=$3

    id -u fivem &>/dev/null || useradd -r -m -d /home/fivem -s /bin/bash fivem
    mkdir -p /home/fivem/artifacts

    S_DIR="/home/fivem/${S_NAME}"
    mkdir -p "${S_DIR}/data"

    START_SCRIPT="${S_DIR}/start_${S_NAME}.sh"
    STOP_SCRIPT="${S_DIR}/stop_${S_NAME}.sh"
    RESTART_SCRIPT="${S_DIR}/restart_${S_NAME}.sh"
    CONSOLE_SCRIPT="${S_DIR}/console_${S_NAME}.sh"
    PIN_SCRIPT="${S_DIR}/pin_${S_NAME}.sh"

    # Start Skript
    cat << EOF > "$START_SCRIPT"
#!/bin/bash
if screen -list | grep -q "\.${S_NAME}\s"; then
    echo "Server '${S_NAME}' läuft bereits!"
    exit 1
fi
echo "Starte FiveM Server '${S_NAME}' auf txAdmin Port ${TX_PORT}..."
cd ${S_DIR}/data || exit 1
screen -L -Logfile ${S_DIR}/txadmin.log -dmS ${S_NAME} /home/fivem/artifacts/run.sh +set txAdminPort ${TX_PORT} +set txAdminServerProfile ${S_NAME}
echo "Server '${S_NAME}' gestartet."
echo ""
echo -e "\e[1m\e[93mTipp:\e[0m Zum Einsehen der Live-Konsole führe aus:"
echo -e "  \e[96m/home/fivem/console_${S_NAME}.sh\e[0m  (oder \e[96mscreen -r ${S_NAME}\e[0m)"
echo ""
sleep 2
PIN=\$(grep -oP 'PIN:\s*\K[0-9]{4}' ${S_DIR}/txadmin.log 2>/dev/null | tail -n 1)
if [ -n "\$PIN" ]; then
    echo -e "\e[1m\e[92m====================================\e[0m"
    echo -e "\e[1m\e[92m  txAdmin Setup PIN: \e[93m\$PIN\e[0m"
    echo -e "\e[1m\e[92m====================================\e[0m"
fi
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

    # Live-Konsole / Screen Attach Skript
    cat << EOF > "$CONSOLE_SCRIPT"
#!/bin/bash
if ! screen -list | grep -q "\.${S_NAME}\s"; then
    echo "Server '${S_NAME}' läuft derzeit nicht."
    exit 1
fi
echo -e "\e[1m\e[92mVerbinde mit Live-Konsole von '${S_NAME}'...\e[0m"
echo -e "\e[1m\e[93mHINWEIS: Zum Verlassen der Konsole drücken: STRG + A, danach D\e[0m"
sleep 2
screen -r ${S_NAME} || screen -x ${S_NAME}
EOF

    # PIN Skript
    cat << EOF > "$PIN_SCRIPT"
#!/bin/bash
if [ -f "${S_DIR}/txadmin.log" ]; then
    PIN=\$(grep -oP 'PIN:\s*\K[0-9]{4}' ${S_DIR}/txadmin.log 2>/dev/null | tail -n 1)
    if [ -n "\$PIN" ]; then
        echo -e "\e[1m\e[92mtxAdmin PIN für ${S_NAME}: \e[93m\$PIN\e[0m"
    else
        echo "Kein PIN im Log gefunden. Öffne die Konsole via /home/fivem/console_${S_NAME}.sh"
    fi
else
    echo "Logdatei existiert nicht. Starte den Server zuerst."
fi
EOF

    chmod +x "$START_SCRIPT" "$STOP_SCRIPT" "$RESTART_SCRIPT" "$CONSOLE_SCRIPT" "$PIN_SCRIPT"

    # Symlinks in /home/fivem
    ln -sf "$START_SCRIPT" "/home/fivem/start_${S_NAME}.sh"
    ln -sf "$STOP_SCRIPT" "/home/fivem/stop_${S_NAME}.sh"
    ln -sf "$RESTART_SCRIPT" "/home/fivem/restart_${S_NAME}.sh"
    ln -sf "$CONSOLE_SCRIPT" "/home/fivem/console_${S_NAME}.sh"
    ln -sf "$PIN_SCRIPT" "/home/fivem/pin_${S_NAME}.sh"

    # Firewall Ports
    ufw allow ${TX_PORT}/tcp comment "txAdmin ${S_NAME}" >/dev/null 2>&1
    ufw allow ${GAME_PORT}/tcp comment "FiveM Game TCP ${S_NAME}" >/dev/null 2>&1
    ufw allow ${GAME_PORT}/udp comment "FiveM Game UDP ${S_NAME}" >/dev/null 2>&1

    chown -R fivem:fivem /home/fivem
}

# --- PHPMYADMIN INSTALLATION ---
setup_phpmyadmin(){
    status "Installiere phpMyAdmin & Apache2 Webserver"
    echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections

    DEBIAN_FRONTEND=noninteractive apt-get install -y apache2 php php-mysql php-mbstring php-zip php-gd php-curl phpmyadmin >/dev/null 2>&1
    
    systemctl enable apache2 >/dev/null 2>&1
    systemctl restart apache2 >/dev/null 2>&1

    ufw allow 80/tcp comment 'HTTP phpMyAdmin' >/dev/null 2>&1

    IP=$(get_server_ip)
    echo -e "${green}${bold}phpMyAdmin erfolgreich installiert!${reset}"
    echo -e "Erreichbar unter: ${blue}http://${IP}/phpmyadmin${reset}"
}

# --- UNINSTALL / PURGE ALL ---
purge_everything(){
    clear
    echo -e "${red}${bold}====================================================${reset}"
    echo -e "${red}${bold}           WARNUNG: ALLES LÖSCHEN (PURGE)           ${reset}"
    echo -e "${red}${bold}====================================================${reset}"
    echo -e "Dies wird:"
    echo -e "  - Alle laufenden FiveM Server-Sessions beenden"
    echo -e "  - Den Ordner /home/fivem und den User 'fivem' komplett löschen"
    echo -e "  - phpMyAdmin & Apache2 (optional) entfernen"
    echo -e "  - Eingestellte UFW Firewall-Regeln zurücksetzen"
    echo ""
    read -r -p "$(echo -e "${red}${bold}Bist du WIRKLICH sicher? (schreibe 'JA'): ${reset}")" CONFIRM_PURGE

    if [ "$CONFIRM_PURGE" != "JA" ]; then
        echo -e "${yellow}Abgebrochen.${reset}"
        return
    fi

    status "Stoppe alle FiveM Server Sessions"
    screen -ls | grep -oP '\t[0-9]+\.\K\S+' | xargs -r -I{} screen -X -S {} quit 2>/dev/null

    status "Lösche User 'fivem' und /home/fivem"
    userdel -r fivem 2>/dev/null
    rm -rf /home/fivem

    read -r -p "$(echo -e "${yellow}Auch MariaDB Datenbank-User löschen? (y/n) [Standard: y]: ${reset}")" RM_DB
    RM_DB=${RM_DB:-y}
    if [[ "$RM_DB" =~ ^[Yy]$ ]]; then
        read -r -p "$(echo -e "${yellow}Name des DB-Users zum Löschen [Standard: external_admin]: ${reset}")" DEL_USER
        DEL_USER=${DEL_USER:-external_admin}
        mariadb -e "DROP USER IF EXISTS '${DEL_USER}'@'%';" 2>/dev/null
        mariadb -e "DROP USER IF EXISTS '${DEL_USER}'@'localhost';" 2>/dev/null
        mariadb -e "FLUSH PRIVILEGES;" 2>/dev/null
    fi

    read -r -p "$(echo -e "${yellow}Auch phpMyAdmin & Apache2 deinstallieren? (y/n) [Standard: y]: ${reset}")" RM_PMA
    RM_PMA=${RM_PMA:-y}
    if [[ "$RM_PMA" =~ ^[Yy]$ ]]; then
        status "Deinstalliere phpMyAdmin & Apache2"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y phpmyadmin apache2 php* >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
    fi

    status "Firewall-Regeln zurücksetzen (UFW)"
    ufw disable >/dev/null 2>&1
    ufw --force reset >/dev/null 2>&1
    ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1
    echo "y" | ufw enable >/dev/null 2>&1

    echo -e "${green}${bold}Alles wurde erfolgreich gelöscht!${reset}"
}

# --- NACHTRÄGLICH SERVER HINZUFÜGEN ---
menu_add_server(){
    clear
    echo -e "${cyan}${bold}--- Neuen FiveM Server hinzufügen ---${reset}"
    read -r -p "$(echo -e "${yellow}Server Name (z. B. server2, roleplay): ${reset}")" S_NAME
    if [ -z "$S_NAME" ]; then
        echo -e "${red}Name darf nicht leer sein!${reset}"
        return
    fi
    S_NAME=$(echo "$S_NAME" | sed 's/[^a-zA-Z0-9_-]/_/g')

    if [ -d "/home/fivem/${S_NAME}" ]; then
        echo -e "${red}Server '${S_NAME}' existiert bereits!${reset}"
        return
    fi

    EXISTING_COUNT=$(find /home/fivem/ -maxdepth 1 -type d -name "server*" 2>/dev/null | wc -l)
    DEFAULT_TX=$((40120 + EXISTING_COUNT))
    DEFAULT_GAME=$((30120 + EXISTING_COUNT * 5))

    read -r -p "$(echo -e "${yellow}txAdmin Port [Standard: $DEFAULT_TX]: ${reset}")" TX_PORT
    TX_PORT=${TX_PORT:-$DEFAULT_TX}

    read -r -p "$(echo -e "${yellow}Game Port (TCP/UDP) [Standard: $DEFAULT_GAME]: ${reset}")" GAME_PORT
    GAME_PORT=${GAME_PORT:-$DEFAULT_GAME}

    add_single_server "$S_NAME" "$TX_PORT" "$GAME_PORT"

    echo "/home/fivem/${S_NAME}/start_${S_NAME}.sh" >> /home/fivem/start_all.sh 2>/dev/null
    echo "/home/fivem/${S_NAME}/stop_${S_NAME}.sh" >> /home/fivem/stop_all.sh 2>/dev/null

    IP=$(get_server_ip)
    echo -e "\n${green}${bold}Server '${S_NAME}' erfolgreich hinzugefügt!${reset}"
    echo -e "  Starten:      ${yellow}su - fivem -c '/home/fivem/start_${S_NAME}.sh'${reset}"
    echo -e "  Live-Konsole: ${yellow}su - fivem -c '/home/fivem/console_${S_NAME}.sh'${reset}"
    echo -e "  Stoppen:      ${yellow}su - fivem -c '/home/fivem/stop_${S_NAME}.sh'${reset}"
    echo -e "  txAdmin:      ${blue}http://${IP}:${TX_PORT}${reset}"
}

# --- ERSTINSTALLATION ---
full_installation(){
    clear
    echo -e "${cyan}${bold}--- Erstinstallation (Debian 12) ---${reset}"

    read -r -p "$(echo -e "${yellow}SSH-Port [Standard: 22]: ${reset}")" SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    echo -e "\n${cyan}${bold}--- MariaDB Konfiguration ---${reset}"
    read -r -p "$(echo -e "${yellow}MariaDB installieren? (y/n) [Standard: y]: ${reset}")" INSTALL_MARIADB
    INSTALL_MARIADB=${INSTALL_MARIADB:-y}

    DB_ACCESS_CHOICE="1"
    DB_USER=""
    DB_PASS=""
    ALLOWED_DB_IP=""

    if [[ "$INSTALL_MARIADB" =~ ^[Yy]$ ]]; then
        echo -e "\nWähle den MariaDB Zugriffsmodus:"
        echo -e "  1) Nur Lokal (127.0.0.1)"
        echo -e "  2) Extern erreichbar (Alle IPs - 0.0.0.0 / %)"
        echo -e "  3) Extern erreichbar (Nur bestimmte IP)"
        read -r -p "$(echo -e "${yellow}Auswahl [1-3] [Standard: 1]: ${reset}")" DB_ACCESS_CHOICE
        DB_ACCESS_CHOICE=${DB_ACCESS_CHOICE:-1}

        if [ "$DB_ACCESS_CHOICE" != "1" ]; then
            read -r -p "$(echo -e "${yellow}Name für DB-Benutzer [Standard: external_admin]: ${reset}")" DB_USER
            DB_USER=${DB_USER:-external_admin}
            while [ -z "$DB_PASS" ]; do
                read -r -p "$(echo -e "${yellow}Passwort für DB-User '$DB_USER': ${reset}")" DB_PASS
            done
            if [ "$DB_ACCESS_CHOICE" == "3" ]; then
                while [ -z "$ALLOWED_DB_IP" ]; do
                    read -r -p "$(echo -e "${yellow}Erlaubte externe IP: ${reset}")" ALLOWED_DB_IP
                done
            fi
        fi
    fi

    read -r -p "$(echo -e "${yellow}\nphpMyAdmin installieren? (y/n) [Standard: y]: ${reset}")" INSTALL_PMA
    INSTALL_PMA=${INSTALL_PMA:-y}

    echo -e "\n${cyan}${bold}--- FiveM Server Konfiguration ---${reset}"
    read -r -p "$(echo -e "${yellow}Wie viele Server initial anlegen? [Standard: 1]: ${reset}")" SERVER_COUNT
    SERVER_COUNT=${SERVER_COUNT:-1}

    declare -a SERVER_NAMES
    declare -a TX_PORTS
    declare -a GAME_PORTS

    for ((i=1; i<=SERVER_COUNT; i++)); do
        echo -e "\nServer #$i:"
        DEFAULT_NAME="server$i"
        read -r -p "$(echo -e "${yellow}Server Name [Standard: $DEFAULT_NAME]: ${reset}")" S_NAME
        S_NAME=${S_NAME:-$DEFAULT_NAME}
        S_NAME=$(echo "$S_NAME" | sed 's/[^a-zA-Z0-9_-]/_/g')
        SERVER_NAMES+=("$S_NAME")

        DEFAULT_TX=$((40120 + i - 1))
        read -r -p "$(echo -e "${yellow}txAdmin Port [Standard: $DEFAULT_TX]: ${reset}")" TX_P
        TX_PORTS+=("${TX_P:-$DEFAULT_TX}")

        DEFAULT_GAME=$((30120 + (i - 1) * 5))
        read -r -p "$(echo -e "${yellow}Game Port [Standard: $DEFAULT_GAME]: ${reset}")" G_P
        GAME_PORTS+=("${G_P:-$DEFAULT_GAME}")
    done

    status "Installiere Grundpakete"
    runCommand "apt update -y && apt upgrade -y"
    runCommand "apt install -y curl git screen xz-utils libssl-dev mariadb-server ufw jq lsof wget"

    # MariaDB Setup
    if [[ "$INSTALL_MARIADB" =~ ^[Yy]$ ]]; then
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
        systemctl restart mariadb

        if [ "$DB_ACCESS_CHOICE" != "1" ]; then
            ESCAPED_DB_PASS=$(printf '%s' "$DB_PASS" | sed "s/'/''/g")
            HOST_SPEC="%"
            if [ "$DB_ACCESS_CHOICE" == "3" ]; then
                HOST_SPEC="$ALLOWED_DB_IP"
            fi
            mariadb -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'${HOST_SPEC}' IDENTIFIED BY '${ESCAPED_DB_PASS}';"
            mariadb -e "GRANT ALL PRIVILEGES ON *.* TO '${DB_USER}'@'${HOST_SPEC}' WITH GRANT OPTION;"
            mariadb -e "FLUSH PRIVILEGES;"
        fi
    fi

    # phpMyAdmin
    if [[ "$INSTALL_PMA" =~ ^[Yy]$ ]]; then
        setup_phpmyadmin
    fi

    # FiveM Artefakte downloaden
    status "Lade FiveM Artefakte"
    id -u fivem &>/dev/null || useradd -r -m -d /home/fivem -s /bin/bash fivem
    mkdir -p /home/fivem/artifacts
    cd /home/fivem/artifacts || exit 1
    LATEST_LINK=$(curl -s https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/ | grep -oP 'href="\./\K[0-9]+-[a-f0-9]+/fx\.tar\.xz' | tail -n 1)
    wget -q https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/$LATEST_LINK -O fx.tar.xz
    tar -xf fx.tar.xz && rm fx.tar.xz

    cat << 'EOF' > /home/fivem/start_all.sh
#!/bin/bash
EOF
    cat << 'EOF' > /home/fivem/stop_all.sh
#!/bin/bash
EOF
    chmod +x /home/fivem/start_all.sh /home/fivem/stop_all.sh

    # Server anlegen
    for ((i=0; i<SERVER_COUNT; i++)); do
        add_single_server "${SERVER_NAMES[$i]}" "${TX_PORTS[$i]}" "${GAME_PORTS[$i]}"
        echo "/home/fivem/${SERVER_NAMES[$i]}/start_${SERVER_NAMES[$i]}.sh" >> /home/fivem/start_all.sh
        echo "/home/fivem/${SERVER_NAMES[$i]}/stop_${SERVER_NAMES[$i]}.sh" >> /home/fivem/stop_all.sh
    done

    # Firewall
    ufw allow ${SSH_PORT}/tcp comment 'SSH Port' >/dev/null 2>&1
    if [[ "$INSTALL_MARIADB" =~ ^[Yy]$ ]]; then
        if [ "$DB_ACCESS_CHOICE" == "2" ]; then
            ufw allow 3306/tcp comment 'MariaDB Global' >/dev/null 2>&1
        elif [ "$DB_ACCESS_CHOICE" == "3" ]; then
            ufw allow from ${ALLOWED_DB_IP} to any port 3306 proto tcp comment 'MariaDB Restricted' >/dev/null 2>&1
        fi
    fi
    echo "y" | ufw enable >/dev/null 2>&1

    IP=$(get_server_ip)
    clear
    echo -e "${green}${bold}====================================================${reset}"
    echo -e "${green}${bold}         ERSTINSTALLATION ABGESCHLOSSEN!           ${reset}"
    echo -e "${green}${bold}====================================================${reset}"
    echo -e "Server IP: ${blue}${IP}${reset}"
    if [[ "$INSTALL_PMA" =~ ^[Yy]$ ]]; then
        echo -e "phpMyAdmin: ${blue}http://${IP}/phpmyadmin${reset}"
    fi
    echo ""
}

# --- SERVER VERWALTUNGSMENU ---
manage_servers_menu(){
    clear
    echo -e "${cyan}${bold}--- Server Verwaltung ---${reset}"
    echo -e "Vorhandene Server:"
    SERVERS=($(find /home/fivem/ -maxdepth 1 -type d -mindepth 1 ! -name "artifacts" ! -name "scripts" -exec basename {} \; 2>/dev/null))
    
    if [ ${#SERVERS[@]} -eq 0 ]; then
        echo -e "${red}Keine Server gefunden!${reset}"
        read -r -p "Taste drücken zum Fortfahren..."
        return
    fi

    for idx in "${!SERVERS[@]}"; do
        S="${SERVERS[$idx]}"
        RUNNING="Gestoppt"
        screen -list | grep -q "\.${S}\s" && RUNNING="LÄUFT"
        echo -e "  $((idx+1))) ${bold}${S}${reset} [ Status: ${cyan}${RUNNING}${reset} ]"
    done
    echo ""
    read -r -p "Wähle einen Server [1-${#SERVERS[@]}]: " SEL
    if ! [[ "$SEL" =~ ^[0-9]+$ ]] || [ "$SEL" -lt 1 ] || [ "$SEL" -gt ${#SERVERS[@]} ]; then
        return
    fi

    CHOSEN="${SERVERS[$((SEL-1))]}"
    echo -e "\nAktion für '${CHOSEN}':"
    echo -e "  1) Starten"
    echo -e "  2) Stoppen"
    echo -e "  3) Neustarten"
    echo -e "  4) Live-Konsole / Screen öffnen (Attach)"
    echo -e "  5) txAdmin PIN / Code anzeigen"
    read -r -p "Auswahl [1-5]: " ACT

    case $ACT in
        1) su - fivem -c "/home/fivem/${CHOSEN}/start_${CHOSEN}.sh" ;;
        2) su - fivem -c "/home/fivem/${CHOSEN}/stop_${CHOSEN}.sh" ;;
        3) su - fivem -c "/home/fivem/${CHOSEN}/restart_${CHOSEN}.sh" ;;
        4) su - fivem -c "/home/fivem/${CHOSEN}/console_${CHOSEN}.sh" ;;
        5) su - fivem -c "/home/fivem/${CHOSEN}/pin_${CHOSEN}.sh" ;;
    esac
    echo ""
    read -r -p "Taste drücken zum Fortfahren..."
}

# --- MAIN MENU ---
while true; do
    clear
    echo -e "${blue}${bold}====================================================${reset}"
    echo -e "${cyan}${bold}   FiveM & MariaDB Manager Wizard (Debian 12)       ${reset}"
    echo -e "${blue}${bold}====================================================${reset}"
    echo -e "  ${cyan}1)${reset} Erstinstallation (MariaDB, phpMyAdmin, Base-Setup)"
    echo -e "  ${cyan}2)${reset} Neuen FiveM-Server hinzufügen"
    echo -e "  ${cyan}3)${reset} Server verwalten (Start, Stop, Live-Konsole, PIN)"
    echo -e "  ${cyan}4)${reset} phpMyAdmin nachinstallieren"
    echo -e "  ${cyan}5)${reset} ${red}${bold}ALLES LÖSCHEN (Full Purge / Deinstallation)${reset}"
    echo -e "  ${cyan}0)${reset} Beenden"
    echo -e "${blue}${bold}====================================================${reset}"
    read -r -p "$(echo -e "${yellow}Auswahl [0-5]: ${reset}")" CHOICE

    case $CHOICE in
        1) full_installation ;;
        2) menu_add_server ;;
        3) manage_servers_menu ;;
        4) setup_phpmyadmin ;;
        5) purge_everything ;;
        0) exit 0 ;;
        *) echo -e "${red}Ungültige Auswahl!${reset}" ; sleep 1 ;;
    esac
done
#!/bin/bash

# Farben & Style
red="\e[0;91m"
green="\e[0;92m"
blue="\e[0;94m"
yellow="\e[0;93m"
bold="\e[1m"
reset="\e[0m"

# Root-Check
if [ "$EUID" -ne 0 ]; then
    echo -e "${red}Bitte führe das Skript als root aus!${reset}"
    exit 1
fi

status(){
    clear
    echo -e "${green}${bold}$@...${reset}"
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

# --- KONFIGURATION & SETUP ---

install_packages(){
    runCommand "apt update -y && apt upgrade -y" "System wird aktualisiert"
    runCommand "apt install -y curl git screen xz-utils libssl-dev mariadb-server ufw jq lsof wget" "Benötigte Pakete werden installiert"
}

setup_mariadb(){
    status "MariaDB für externen Zugriff konfigurieren"
    
    # Bind-Address anpassen (auch wenn auskommentiert oder mit variablen Leerzeichen)
    CONF_FILE="/etc/mysql/mariadb.conf.d/50-server.cnf"
    if [ -f "$CONF_FILE" ]; then
        sed -i -E 's/^\s*#?\s*bind-address\s*=.*/bind-address = 0.0.0.0/' "$CONF_FILE"
    fi
    runCommand "systemctl restart mariadb"
    
    clear
    echo -e "${yellow}${bold}=== Datenbank-Konfiguration ===${reset}"
    read -r -p "Gib das Passwort für den externen DB-User 'external_admin' ein: " DB_PASS
    
    if [ -z "$DB_PASS" ]; then
        echo -e "${red}Passwort darf nicht leer sein! Vorgang abgebrochen.${reset}"
        exit 1
    fi

    # Passwort für SQL-String maskieren
    ESCAPED_DB_PASS=$(printf '%s' "$DB_PASS" | sed "s/'/''/g")

    mariadb -e "CREATE USER IF NOT EXISTS 'external_admin'@'%' IDENTIFIED BY '${ESCAPED_DB_PASS}';"
    mariadb -e "GRANT ALL PRIVILEGES ON *.* TO 'external_admin'@'%' WITH GRANT OPTION;"
    mariadb -e "CREATE DATABASE IF NOT EXISTS server1_db;"
    mariadb -e "CREATE DATABASE IF NOT EXISTS server2_db;"
    mariadb -e "FLUSH PRIVILEGES;"
}

setup_fivem(){
    status "Ordnerstruktur wird angelegt"
    
    # Dedicated User anlegen falls nicht vorhanden
    id -u fivem &>/dev/null || useradd -r -m -d /home/fivem -s /bin/bash fivem

    runCommand "mkdir -p /home/fivem/artifacts"
    runCommand "mkdir -p /home/fivem/server1/data"
    runCommand "mkdir -p /home/fivem/server2/data"

    status "Lade neueste FiveM-Artefakte herunter"
    cd /home/fivem/artifacts || exit 1
    
    LATEST_LINK=$(curl -s https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/ | grep -oP 'href="\./\K[0-9]+-[a-f0-9]+/fx\.tar\.xz' | tail -n 1)
    
    if [ -z "$LATEST_LINK" ]; then
        echo -e "${red}Fehler: Konnte keine Artefakte finden.${reset}"
        exit 1
    fi

    runCommand "wget -q https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/$LATEST_LINK -O fx.tar.xz" "Artefakt-Download"
    runCommand "tar -xf fx.tar.xz && rm fx.tar.xz" "Entpacken der Artefakte"

    status "Erstelle Start-Skripte & Control-Helper"

    cat << 'EOF' > /home/fivem/server1/start.sh
#!/bin/bash
cd /home/fivem/server1/data || exit 1
/home/fivem/artifacts/run.sh +set txAdminPort 40120 +set txAdminServerProfile server1
EOF
    chmod +x /home/fivem/server1/start.sh

    cat << 'EOF' > /home/fivem/server2/start.sh
#!/bin/bash
cd /home/fivem/server2/data || exit 1
/home/fivem/artifacts/run.sh +set txAdminPort 40000 +set txAdminServerProfile server2
EOF
    chmod +x /home/fivem/server2/start.sh

    chown -R fivem:fivem /home/fivem
}

setup_firewall(){
    status "Konfiguriere UFW Firewall"
    # SSH explizit erlauben vor UFW Activation (Sicherheitsnetz gegen Lockout)
    ufw allow 22/tcp comment 'SSH Port' > /dev/null
    ufw allow 3306/tcp comment 'MariaDB Remote' > /dev/null
    ufw allow 40120/tcp comment 'txAdmin Server 1' > /dev/null
    ufw allow 40000/tcp comment 'txAdmin Server 2' > /dev/null
    ufw allow 30120/tcp comment 'FiveM Server 1 Game TCP' > /dev/null
    ufw allow 30120/udp comment 'FiveM Server 1 Game UDP' > /dev/null
    ufw allow 30125/tcp comment 'FiveM Server 2 Game TCP' > /dev/null
    ufw allow 30125/udp comment 'FiveM Server 2 Game UDP' > /dev/null
    echo "y" | ufw enable > /dev/null
}

# --- MAIN EXECUTION ---
clear
echo -e "${blue}${bold}====================================================${reset}"
echo -e "${green}${bold}      FiveM Dual-Server Installer (Debian 13)       ${reset}"
echo -e "${blue}${bold}====================================================${reset}"
sleep 2

install_packages
setup_mariadb
setup_fivem
setup_firewall

# Robustere IP-Erfassung via regex auf 'src' Token
IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || hostname -I | awk '{print $1}')

clear
echo -e "${green}${bold}====================================================${reset}"
echo -e "${green}${bold}           SETUP ERFOLGREICH ABGESCHLOSSEN!          ${reset}"
echo -e "${green}${bold}====================================================${reset}"
echo ""
echo -e "${bold}MariaDB Info:${reset}"
echo -e "  Host: ${blue}${IP}${reset} (Port 3306)"
echo -e "  User: ${blue}external_admin${reset}"
echo -e "  Databases: ${blue}server1_db${reset}, ${blue}server2_db${reset}"
echo ""
echo -e "${bold}Server 1 (txAdmin Port 40120):${reset}"
echo -e "  Starten via: ${yellow}su - fivem -c 'screen -S server1 /home/fivem/server1/start.sh'${reset}"
echo -e "  Webinterface: ${blue}http://${IP}:40120${reset}"
echo ""
echo -e "${bold}Server 2 (txAdmin Port 40000):${reset}"
echo -e "  Starten via: ${yellow}su - fivem -c 'screen -S server2 /home/fivem/server2/start.sh'${reset}"
echo -e "  Webinterface: ${blue}http://${IP}:40000${reset}"
echo -e "${green}${bold}====================================================${reset}"
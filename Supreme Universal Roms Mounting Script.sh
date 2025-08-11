#!/bin/bash

INSTALLER_SCRIPT="/home/pi/smb_rom_installer.sh"

# === Friendly Box Welcome Message with Clean Layout ===
dialog --title "Welcome" --msgbox "\
======= Supreme Universal Roms Mounting Script =======

First things first!

Lets mount a shared roms folder from your PC to use on your
Raspberry Pi - With auto-mount, backup, and RetroPie integration.

Let's get started!" 15 65

# Ensure installer script exists at expected path
if [ "$0" != "$INSTALLER_SCRIPT" ]; then
  cp "$0" "$INSTALLER_SCRIPT"
  chmod +x "$INSTALLER_SCRIPT"
fi

# 1. Install dependencies
MISSING_PKGS=()
for pkg in dialog smbclient cifs-utils; do
  dpkg -s "$pkg" &>/dev/null || MISSING_PKGS+=("$pkg")
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
  echo "Installing missing packages: ${MISSING_PKGS[*]}"
  sudo apt update
  sudo apt install -y "${MISSING_PKGS[@]}"
fi

# 2. Show setup instructions
dialog --title "PC Sharing Instructions" --msgbox "\
Make sure your Windows PC is:
- On the same network as the Pi
- Sharing the folder containing your ROMs
- Using SMB (Windows File Sharing)
- Set to allow access for the user you'll log in as

You may need to right-click the folder ? Properties ? Sharing ? Advanced Sharing." 15 60

# 3. Get IP address of Windows PC
dialog --inputbox "Enter the IP address of your PC (with SMB share):" 8 50 2>/tmp/ip_input
if [ $? -ne 0 ]; then
  dialog --msgbox "Cancelled. Exiting setup." 6 40
  clear
  exit 1
fi
PC_IP=$(< /tmp/ip_input)
rm -f /tmp/ip_input

# 4. Validate IP subnet
LOCAL_SUBNET=$(hostname -I | awk -F. '{print $1"."$2"."$3}')
IP_SUBNET=$(echo "$PC_IP" | awk -F. '{print $1"."$2"."$3}')

if [[ "$LOCAL_SUBNET" != "$IP_SUBNET" ]]; then
  dialog --msgbox "The IP address $PC_IP is not on your local network ($LOCAL_SUBNET.x)." 8 50
  clear
  exit 1
fi

# 5. Credential check
AUTH_ARGS="-N"
CREDENTIALS_FILE=""
if smbclient -L "//$PC_IP" -N 2>&1 | grep -q "NT_STATUS_ACCESS_DENIED"; then
  dialog --msgbox "We found a PC matching the IP you provided, but it is asking for login credentials." 8 60

  dialog --inputbox "Enter your Windows username:" 8 40 2>/tmp/user
  [ $? -ne 0 ] && { dialog --msgbox "Cancelled. Exiting setup." 6 40; clear; exit 1; }
  USERNAME=$(< /tmp/user)

  dialog --insecure --passwordbox "Enter your Windows password:" 8 40 2>/tmp/pass
  [ $? -ne 0 ] && { dialog --msgbox "Cancelled. Exiting setup." 6 40; clear; exit 1; }
  PASSWORD=$(< /tmp/pass)
  rm -f /tmp/user /tmp/pass

  CREDENTIALS_FILE="/home/pi/.smbcredentials"
  echo -e "username=$USERNAME\npassword=$PASSWORD" | sudo tee "$CREDENTIALS_FILE" >/dev/null
  sudo chmod 600 "$CREDENTIALS_FILE"
  AUTH_ARGS="-U $USERNAME%$PASSWORD"
fi

# 6. Share and subfolder selection
while true; do
  SHARES=$(smbclient -L "//$PC_IP" $AUTH_ARGS 2>/dev/null | awk '/Disk/ {print $1}' | grep -vE '^$|^\s*$|^IPC$|^print\$')
  if [ -z "$SHARES" ]; then
    dialog --msgbox "No shared folders found on $PC_IP." 7 50
    clear
    exit 1
  fi

  SHARE=$(dialog --menu "Select a share:" 15 50 6 $(for s in $SHARES; do echo "$s $s"; done) 3>&1 1>&2 2>&3)
  [ -z "$SHARE" ] && { dialog --msgbox "No share selected." 6 40; clear; exit 1; }

  CURRENT_PATH=""
  while true; do
    CMD="smbclient \"//$PC_IP/$SHARE\" $AUTH_ARGS -c 'ls \"$CURRENT_PATH\"'"
    DIRS=$(eval $CMD 2>/dev/null | awk '/^[ ]+[^ ]+[ ]+D/ { sub(/^ +/, "", $0); print $1 }' | grep -vE '^\.{1,2}$')

    MENU_ITEMS=()
    MENU_ITEMS+=("[SELECT ROOT]" "Use the top-level share folder")
    MENU_ITEMS+=("[CHANGE SHARE]" "Go back to choose a different share")
    [ -n "$CURRENT_PATH" ] && MENU_ITEMS+=(".." "Back to previous folder")
    for dir in $DIRS; do
      MENU_ITEMS+=("$dir" "$dir/")
    done
    MENU_ITEMS+=("[USE THIS FOLDER]" "Mount this folder as ROM directory")

    SELECTION=$(dialog --menu "Browsing: /$CURRENT_PATH" 20 60 15 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
      dialog --yesno "Cancel browsing?\n\nYES: Choose a different share\nNO: Continue browsing" 10 60
      if [ $? -eq 0 ]; then exec "$INSTALLER_SCRIPT"; else continue; fi
    fi

    case "$SELECTION" in
      "[USE THIS FOLDER]") SELECTED_FOLDER="$CURRENT_PATH"; break 2 ;;
      "[SELECT ROOT]") SELECTED_FOLDER=""; break 2 ;;
      "[CHANGE SHARE]") break ;;
      "..") CURRENT_PATH=$(dirname "$CURRENT_PATH"); [ "$CURRENT_PATH" = "." ] && CURRENT_PATH="" ;;
      *) CURRENT_PATH="${CURRENT_PATH:+$CURRENT_PATH/}$SELECTION"; CURRENT_PATH=$(echo "$CURRENT_PATH" | sed 's|^/||; s|//*|/|g') ;;
    esac
  done
done

# 7. Generate toggle_roms.sh
sudo tee /usr/local/bin/toggle_roms.sh >/dev/null <<EOF
#!/bin/bash

ROM_PATH="/home/pi/RetroPie/roms"
ROM_BACKUP="/home/pi/RetroPie/roms-offline"
SHARE_PATH="//$PC_IP/$SHARE"
SUBFOLDER="$SELECTED_FOLDER"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-/home/pi/.smbcredentials}"
MOUNT_UNIT="home-pi-RetroPie-roms.mount"
MOUNT_PATH="/etc/systemd/system/\$MOUNT_UNIT"
INSTALLER="/home/pi/smb_rom_installer.sh"

msg() { dialog --msgbox "\$1" 10 60; }

ask_reboot() {
  dialog --yesno "Reboot now?" 8 50
  [ \$? -eq 0 ] && sudo reboot || msg "Reboot later to apply changes."
}

create_unit() {
  sudo tee "\$MOUNT_PATH" >/dev/null <<EOM
[Unit]
Description=Auto-mount Network ROMs
After=network-online.target
Wants=network-online.target

[Mount]
What=\$SHARE_PATH/\$SUBFOLDER
Where=\$ROM_PATH
Type=cifs
Options=\$( [ -n "\$CREDENTIALS_FILE" ] && echo "credentials=\$CREDENTIALS_FILE," || echo "guest," )vers=3.0,iocharset=utf8,file_mode=0777,dir_mode=0777
TimeoutSec=30

[Install]
WantedBy=multi-user.target
EOM

  sudo systemctl daemon-reexec >/dev/null 2>&1
  sudo systemctl enable "\$MOUNT_UNIT" >/dev/null 2>&1
  sudo systemctl start "\$MOUNT_UNIT" >/dev/null 2>&1
}

remove_unit() {
  sudo systemctl stop "\$MOUNT_UNIT" >/dev/null 2>&1
  sudo systemctl disable "\$MOUNT_UNIT" >/dev/null 2>&1
  sudo rm -f "\$MOUNT_PATH" >/dev/null 2>&1
  sudo systemctl daemon-reexec >/dev/null 2>&1
}

rerun() {
  if mountpoint -q "\$ROM_PATH"; then
    sudo umount "\$ROM_PATH"
    remove_unit
    sudo rm -rf "\$ROM_PATH"
    sudo mv "\$ROM_BACKUP" "\$ROM_PATH"
    msg "Did a quick check. Local ROMs restored and auto-mount disabled. Now opening setup."
  else
    msg "Did a quick check. Network share not mounted. Now opening setup."
  fi

  if [ -x "\$INSTALLER" ]; then
    clear; bash "\$INSTALLER"
  else
    msg "Installer script not found at: \$INSTALLER"
  fi
  exit 0
}

while true; do
  STATUS_MSG=\$(mountpoint -q "\$ROM_PATH" && echo "Status: Mounted" || echo "Status: Not Mounted")
  SHARE_DISPLAY="\$SHARE_PATH"
  [ -n "\$SUBFOLDER" ] && SHARE_DISPLAY="\$SHARE_PATH/\$SUBFOLDER"

  dialog --title "Mount Toggle set to: \$ROM_PATH" --menu "\
Currently set to mount:

  From: \$SHARE_DISPLAY
  To:   \$ROM_PATH
  \$STATUS_MSG

Choose an option:" 20 70 4 \
    1 "Mount Network Folder (enable auto-mount)" \
    2 "Restore Local Folder (disable auto-mount)" \
    3 "Change Network Share / Re-run Setup" \
    4 "Exit" 2>/tmp/choice

  if [ ! -s /tmp/choice ]; then
    clear
    exit 0
  fi

  opt=\$(< /tmp/choice)
  rm -f /tmp/choice

  case \$opt in
    1)
      if mountpoint -q "\$ROM_PATH"; then
        msg "Already mounted."
      elif [ -d "\$ROM_BACKUP" ]; then
        msg "Backup exists — cannot overwrite."
      else
        sudo mv "\$ROM_PATH" "\$ROM_BACKUP"
        sudo mkdir -p "\$ROM_PATH"
        create_unit; sleep 2
        if mountpoint -q "\$ROM_PATH"; then
          msg "Mounted and auto-mount enabled!"
          ask_reboot
        else
          sudo rm -rf "\$ROM_PATH"
          sudo mv "\$ROM_BACKUP" "\$ROM_PATH"
          remove_unit
          msg "Mount failed — restored local ROMs."
        fi
      fi
      ;;
    2)
      if mountpoint -q "\$ROM_PATH"; then
        sudo umount "\$ROM_PATH"
        remove_unit
        sudo rm -rf "\$ROM_PATH"
        sudo mv "\$ROM_BACKUP" "\$ROM_PATH"
        msg "Did a quick check. Local ROMs restored and auto-mount disabled. Now opening setup."
        ask_reboot
      else
        msg "Did a quick check. Network share not mounted. Now opening setup."
      fi
      ;;
    3)
      rerun
      ;;
    4)
      clear
      exit 0
      ;;
  esac
done
EOF

sudo chmod +x /usr/local/bin/toggle_roms.sh

# 8. Optionally add toggle to RetroPie menu
dialog --yesno "Add ROM toggle script to RetroPie menu?" 7 50
if [ $? -eq 0 ]; then
  MENU_PATH="/home/pi/RetroPie/retropiemenu"
  mkdir -p "$MENU_PATH"
  echo -e "#!/bin/bash\n/usr/local/bin/toggle_roms.sh" > "$MENU_PATH/toggle roms.sh"
  chmod +x "$MENU_PATH/toggle roms.sh"

sleep 3

cp /opt/retropie/configs/all/emulationstation/gamelists/retropie/gamelist.xml /opt/retropie/configs/all/emulationstation/gamelists/retropie/gamelist.xml.bkp
cp /opt/retropie/configs/all/emulationstation/gamelists/retropie/gamelist.xml /tmp

grep -v "</gameList>" /tmp/gamelist.xml > /tmp/templist.xml

ifexist=$(grep -c "toggle roms" /tmp/templist.xml)

if [[ ${ifexist} -gt 0 ]]; then
  echo "already in gamelist.xml" > /tmp/exists
else
  cat <<EOF >> /tmp/templist.xml
  <game>
    <path>./toggle roms.sh</path>
    <name>Toggle Rom Mounting</name>
    <desc>The Supreme Universal Roms Mounting Script.</desc>
    <image>/home/pi/RetroPie/retropiemenu/icons/toggle roms.png</image>
    <playcount>1</playcount>
    <lastplayed></lastplayed>
  </game>
</gameList>
EOF

  cp /tmp/templist.xml /opt/retropie/configs/all/emulationstation/gamelists/retropie/gamelist.xml
  cp /tmp/templist.xml /home/pi/RetroPie/retropiemenu/gamelist.xml

fi

# Download icon from GitHub
ICON_URL="https://raw.githubusercontent.com/SupremePi/Supreme-Universal-Mounting/main/Supreme-Universal-Mounting.png"
ICON_DIR="/home/pi/RetroPie/retropiemenu/icons"
ICON_PATH="$ICON_DIR/toggle roms.png"

#echo "Fetching menu icon..."
mkdir -p "$ICON_DIR"
wget -q -O "$ICON_PATH" "$ICON_URL"

fi

# 9. Prompt to launch toggle script now
dialog --yesno "Setup complete!\n\nWould you like to mount the network folder now?" 10 60
if [ $? -eq 0 ]; then
  clear
  /usr/local/bin/toggle_roms.sh
else
  dialog --msgbox "You can re-open this tool anytime with:\n\n  /usr/local/bin/toggle_roms.sh\n\nOr from the RetroPie menu if you added it." 10 60
  clear
fi

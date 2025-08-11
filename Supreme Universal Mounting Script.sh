#!/bin/bash

INSTALLER_SCRIPT="/home/pi/smb_rom_installer.sh"

# === Friendly Box Welcome Message with Clean Layout ===
dialog --title "Welcome" --msgbox "\
========= Supreme Universal Mounting Script =========

First things first!

Lets mount a shared folder from your PC to any folder on your
Raspberry Pi - With auto-mount, backup, and RetroPie integration.

Let's get started!" 15 65

# Save script copy to standard location if not already there
if [ "$0" != "$INSTALLER_SCRIPT" ]; then
  cp "$0" "$INSTALLER_SCRIPT"
  chmod +x "$INSTALLER_SCRIPT"
fi

# Ensure required packages are installed
MISSING_PKGS=()
for pkg in dialog smbclient cifs-utils; do
  dpkg -s "$pkg" &>/dev/null || MISSING_PKGS+=("$pkg")
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
  echo "Installing: ${MISSING_PKGS[*]}"
  sudo apt update
  sudo apt install -y "${MISSING_PKGS[@]}"
fi

# === Step 1: Select LOCAL MOUNT TARGET ===
CURRENT_LOCAL="/"
while true; do
  DIRS=$(ls -p "$CURRENT_LOCAL" 2>/dev/null | grep '/$' | sed 's:/$::')
  MENU_ITEMS=()
  MENU_ITEMS+=("[USE THIS FOLDER]" "Mount point for network share")
  [ "$CURRENT_LOCAL" != "/" ] && MENU_ITEMS+=(".." "Go up")
  for dir in $DIRS; do
    MENU_ITEMS+=("$dir" "$dir/")
  done

  SELECTION=$(dialog --menu "Select folder on Pi to mount TO:\n(Current: $CURRENT_LOCAL)" 20 60 15 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)
  if [ $? -ne 0 ]; then clear; exit 1; fi

  case "$SELECTION" in
    "[USE THIS FOLDER]") MOUNT_TARGET="$CURRENT_LOCAL"; break ;;
    "..") CURRENT_LOCAL=$(dirname "$CURRENT_LOCAL"); [ "$CURRENT_LOCAL" = "." ] && CURRENT_LOCAL="/" ;;
    *) CURRENT_LOCAL="${CURRENT_LOCAL%/}/$SELECTION" ;;
  esac
done

# === Step 2: PC Instructions ===
dialog --title "PC Sharing Instructions" --msgbox "\
Make sure your Windows PC is:
- On the same network
- Sharing the folder via SMB
- Allows user login (if needed)" 15 60

# === Step 3: Ask for PC IP ===
dialog --inputbox "Enter PC IP (with SMB share):" 8 50 2>/tmp/ip_input
[ $? -ne 0 ] && clear && exit 1
PC_IP=$(< /tmp/ip_input)
rm -f /tmp/ip_input

# === Step 4: Validate IP subnet ===
LOCAL_SUBNET=$(hostname -I | awk -F. '{print $1"."$2"."$3}')
IP_SUBNET=$(echo "$PC_IP" | awk -F. '{print $1"."$2"."$3}')
[[ "$LOCAL_SUBNET" != "$IP_SUBNET" ]] && dialog --msgbox "IP not in subnet ($LOCAL_SUBNET.x)" 8 50 && clear && exit 1

# === Step 5: Check Credentials ===
AUTH_ARGS="-N"
CREDENTIALS_FILE=""
if smbclient -L "//$PC_IP" -N 2>&1 | grep -q "NT_STATUS_ACCESS_DENIED"; then
  dialog --msgbox "PC requires login." 8 40
  dialog --inputbox "Username:" 8 40 2>/tmp/user || exit 1
  dialog --insecure --passwordbox "Password:" 8 40 2>/tmp/pass || exit 1
  USERNAME=$(< /tmp/user)
  PASSWORD=$(< /tmp/pass)
  rm -f /tmp/user /tmp/pass
  CREDENTIALS_FILE="/home/pi/.smbcredentials"
  echo -e "username=$USERNAME\npassword=$PASSWORD" | sudo tee "$CREDENTIALS_FILE" >/dev/null
  sudo chmod 600 "$CREDENTIALS_FILE"
  AUTH_ARGS="-U $USERNAME%$PASSWORD"
fi

# === Step 6: Select Share + Folder ===
while true; do
  SHARES=$(smbclient -L "//$PC_IP" $AUTH_ARGS 2>/dev/null | awk '/Disk/ {print $1}' | grep -vE '^$|^\s*$|^IPC$|^print\$')
  [ -z "$SHARES" ] && dialog --msgbox "No shares found." 7 50 && clear && exit 1
  SHARE=$(dialog --menu "Select a share:" 15 50 6 $(for s in $SHARES; do echo "$s $s"; done) 3>&1 1>&2 2>&3)
  [ -z "$SHARE" ] && clear && exit 1

  CURRENT_PATH=""
  while true; do
    CMD="smbclient \"//$PC_IP/$SHARE\" $AUTH_ARGS -c 'ls \"$CURRENT_PATH\"'"
    DIRS=$(eval $CMD 2>/dev/null | awk '/^[ ]+[^ ]+[ ]+D/ { sub(/^ +/, "", $0); print $1 }' | grep -vE '^\.{1,2}$')

    MENU_ITEMS=()
    MENU_ITEMS+=("[SELECT ROOT]" "Top-level share")
    MENU_ITEMS+=("[CHANGE SHARE]" "Pick a different share")
    [ -n "$CURRENT_PATH" ] && MENU_ITEMS+=(".." "Back up")
    for dir in $DIRS; do
      MENU_ITEMS+=("$dir" "$dir/")
    done
    MENU_ITEMS+=("[USE THIS FOLDER]" "Mount this folder")

    SELECTION=$(dialog --menu "Browsing: /$CURRENT_PATH" 20 60 15 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
      dialog --yesno "Cancel browsing?\nYES: exit\nNO: continue" 10 60 && [ $? -eq 0 ] && clear && exit 1
      continue
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

# === Step 7: Generate toggle_network_mount.sh ===
BACKUP_PATH="${MOUNT_TARGET}-offline"
MOUNT_UNIT=$(echo "$MOUNT_TARGET" | sed 's|^/||; s|/|-|g').mount
MOUNT_PATH="/etc/systemd/system/$MOUNT_UNIT"

sudo tee /usr/local/bin/toggle_network_mount.sh >/dev/null <<'EOF'
#!/bin/bash

MOUNT_TARGET="<MOUNT_TARGET>"
BACKUP_PATH="<BACKUP_PATH>"
SHARE_PATH="<SHARE_PATH>"
SUBFOLDER="<SUBFOLDER>"
CREDENTIALS_FILE="<CREDENTIALS_FILE>"
MOUNT_UNIT="<MOUNT_UNIT>"
MOUNT_PATH="<MOUNT_PATH>"
INSTALLER="<INSTALLER_SCRIPT>"

msg() { dialog --msgbox "$1" 10 60; }

ask_reboot() {
  dialog --yesno "Reboot now?" 8 50
  [ $? -eq 0 ] && sudo reboot || msg "Reboot later to apply changes."
}

create_unit() {
  sudo systemctl stop "$MOUNT_UNIT" 2>/dev/null
  sudo systemctl disable "$MOUNT_UNIT" 2>/dev/null
  sudo rm -f "$MOUNT_PATH"

  WHAT=$(printf '%q' "$SHARE_PATH/$SUBFOLDER")
  WHERE=$(printf '%q' "$MOUNT_TARGET")

  sudo tee "$MOUNT_PATH" >/dev/null <<EOM
[Unit]
Description=Auto-mount Network Share
After=network-online.target
Wants=network-online.target

[Mount]
What=$WHAT
Where=$WHERE
Type=cifs
Options=$( [ -n "$CREDENTIALS_FILE" ] && echo "credentials=$CREDENTIALS_FILE," || echo "guest," )vers=3.0,iocharset=utf8,file_mode=0777,dir_mode=0777
TimeoutSec=30

[Install]
WantedBy=multi-user.target
EOM

  sudo systemctl daemon-reexec >/dev/null 2>&1
  sudo systemctl enable "$MOUNT_UNIT" >/dev/null 2>&1
  sudo systemctl start "$MOUNT_UNIT" >/dev/null 2>&1
}

remove_unit() {
  sudo systemctl stop "$MOUNT_UNIT" >/dev/null 2>&1
  sudo systemctl disable "$MOUNT_UNIT" >/dev/null 2>&1
  sudo rm -f "$MOUNT_PATH" >/dev/null 2>&1
  sudo systemctl daemon-reexec >/dev/null 2>&1
}

rerun() {
  if mountpoint -q "$MOUNT_TARGET"; then
    sudo umount "$MOUNT_TARGET"
    remove_unit
    sudo rm -rf "$MOUNT_TARGET"
    sudo mv "$BACKUP_PATH" "$MOUNT_TARGET"
    msg "Did a quick check. Local content restored and auto-mount disabled. Now opening setup."
  else
    msg "Did a quick check. Network share not mounted. Now opening setup."
  fi
  [ -x "$INSTALLER" ] && clear && bash "$INSTALLER"
  exit 0
}

while true; do
  STATUS_MSG=$(mountpoint -q "$MOUNT_TARGET" && echo "Status: Mounted" || echo "Status: Not Mounted")
  SHARE_DISPLAY="$SHARE_PATH"
  [ -n "$SUBFOLDER" ] && SHARE_DISPLAY="$SHARE_PATH/$SUBFOLDER"

  dialog --title "Mount Toggle set to: \$MOUNT_TARGET" --menu "\
Currently set to mount:

  From: $SHARE_DISPLAY
  To:   $MOUNT_TARGET
  $STATUS_MSG

Choose an option:" 20 70 4 \
    1 "Mount Network Folder (enable auto-mount)" \
    2 "Restore Local Folder (disable auto-mount)" \
    3 "Change Network Share / Re-run Setup" \
    4 "Exit" 2>/tmp/choice

  if [ ! -s /tmp/choice ]; then
    clear
    exit 0
  fi
  opt=$(< /tmp/choice)
  rm -f /tmp/choice

  case $opt in
    1)
      if mountpoint -q "$MOUNT_TARGET"; then
        msg "Already mounted."
      elif [ -d "$BACKUP_PATH" ]; then
        msg "Backup exists — cannot overwrite."
      else
        sudo mkdir -p "$(dirname "$BACKUP_PATH")"
        sudo mv "$MOUNT_TARGET" "$BACKUP_PATH"
        sudo mkdir -p "$MOUNT_TARGET"
        create_unit; sleep 2
        if mountpoint -q "$MOUNT_TARGET"; then
          msg "Mounted and auto-mount enabled!"
          ask_reboot
        else
          sudo rm -rf "$MOUNT_TARGET"
          sudo mv "$BACKUP_PATH" "$MOUNT_TARGET"
          remove_unit
          msg "Mount failed. Restored local content."
        fi
      fi
      ;;
    2)
      if mountpoint -q "$MOUNT_TARGET"; then
        sudo umount "$MOUNT_TARGET"
        remove_unit
        sudo rm -rf "$MOUNT_TARGET"
        sudo mv "$BACKUP_PATH" "$MOUNT_TARGET"
        msg "Did a quick check. Local content restored and auto-mount disabled. Now opening setup."
        ask_reboot
      else
        msg "Did a quick check. Network share not mounted. Now opening setup."
      fi
      ;;
    3) rerun ;;
    4) clear; exit 0 ;;
  esac
done
EOF

# Fill in template values
sudo sed -i "s|<MOUNT_TARGET>|$MOUNT_TARGET|g" /usr/local/bin/toggle_network_mount.sh
sudo sed -i "s|<BACKUP_PATH>|$BACKUP_PATH|g" /usr/local/bin/toggle_network_mount.sh
sudo sed -i "s|<SHARE_PATH>|//$PC_IP/$SHARE|g" /usr/local/bin/toggle_network_mount.sh
sudo sed -i "s|<SUBFOLDER>|$SELECTED_FOLDER|g" /usr/local/bin/toggle_network_mount.sh
sudo sed -i "s|<CREDENTIALS_FILE>|${CREDENTIALS_FILE}|g" /usr/local/bin/toggle_network_mount.sh
sudo sed -i "s|<MOUNT_UNIT>|$MOUNT_UNIT|g" /usr/local/bin/toggle_network_mount.sh
sudo sed -i "s|<MOUNT_PATH>|$MOUNT_PATH|g" /usr/local/bin/toggle_network_mount.sh
sudo sed -i "s|<INSTALLER_SCRIPT>|$INSTALLER_SCRIPT|g" /usr/local/bin/toggle_network_mount.sh

sudo chmod +x /usr/local/bin/toggle_network_mount.sh

# === RetroPie Menu Entry ===
dialog --yesno "Add network toggle to RetroPie menu?" 7 50
if [ $? -eq 0 ]; then
  MENU_PATH="/home/pi/RetroPie/retropiemenu"
  mkdir -p "$MENU_PATH"
  echo -e "#!/bin/bash\n/usr/local/bin/toggle_network_mount.sh" > "$MENU_PATH/Toggle Network Mount.sh"
  chmod +x "$MENU_PATH/Toggle Network Mount.sh"

sleep 3

cp /opt/retropie/configs/all/emulationstation/gamelists/retropie/gamelist.xml /opt/retropie/configs/all/emulationstation/gamelists/retropie/gamelist.xml.bkp
cp /opt/retropie/configs/all/emulationstation/gamelists/retropie/gamelist.xml /tmp

grep -v "</gameList>" /tmp/gamelist.xml > /tmp/templist.xml

ifexist=$(grep -c "Toggle Network Mount" /tmp/templist.xml)

if [[ ${ifexist} -gt 0 ]]; then
  echo "already in gamelist.xml" > /tmp/exists
else
  cat <<EOF >> /tmp/templist.xml
  <game>
    <path>./Toggle Network Mount.sh</path>
    <name>Toggle Network Mount</name>
    <desc>The Supreme Universal Mounting Script.</desc>
    <image>/home/pi/RetroPie/retropiemenu/icons/Toggle Network Mount.png</image>
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
ICON_PATH="$ICON_DIR/Toggle Network Mount.png"

#echo "Fetching menu icon..."
mkdir -p "$ICON_DIR"
wget -q -O "$ICON_PATH" "$ICON_URL"


fi

dialog --yesno "Setup complete!\n\nWould you like to mount the network folder now?" 10 60
if [ $? -eq 0 ]; then
  clear
  /usr/local/bin/toggle_network_mount.sh
else
  dialog --msgbox "You can re-open this tool anytime with:\n\n  /usr/local/bin/toggle_network_mount.sh\n\nOr from the RetroPie menu if you added it." 10 60
  clear
fi

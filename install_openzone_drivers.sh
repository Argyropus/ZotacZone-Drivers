#!/bin/bash
# ==============================================================================
#  ZOTAC ZONE STEAMOS DIAL DAEMON INSTALLER
# ==============================================================================
#  Drivers by: flukejones (Luke D. Jones)
#  Installer by: Pfahli
#  Modified for SteamOS (Dial Daemon Only + Read/Write Unlock)
# ==============================================================================

# --- Colors & Formatting ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Configuration ---
# Dial Config
DIAL_INSTALL_DIR="/usr/local/bin"
DIAL_SCRIPT_NAME="zotac_dial_daemon.py"
DIAL_SERVICE_NAME="zotac-dials.service"
DIAL_SERVICE_PATH="/etc/systemd/system/$DIAL_SERVICE_NAME"

# --- Helper Functions ---
log_header() { echo -e "\n${BLUE}${BOLD}:: $1${NC}"; }
log_info()   { echo -e "   ${CYAN}ℹ${NC} $1"; }
log_success() { echo -e "   ${GREEN}✔${NC} $1"; }
log_warn()   { echo -e "   ${YELLOW}⚠${NC} $1"; }
log_error()  { echo -e "   ${RED}✖ $1${NC}"; }

print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "############################################################"
    echo "#                                                          #"
    echo "#       ZOTAC ZONE DIAL DAEMON INSTALLER (SteamOS)         #"
    echo "#                                                          #"
    echo "#   Target OS:   SteamOS (Read/Write Unlock Included)      #"
    echo "#   Installs:    Steam Gaming Mode (Raw HID Access)        #"
    echo "#                                                          #"
    echo "############################################################"
    echo -e "${NC}"
}

if [ "$EUID" -ne 0 ]; then
   log_error "This script must be run as root."
   echo -e "   Please run: ${BOLD}sudo $0${NC}"
   exit 1
fi

print_banner

# --- Step 0: Disclaimer & SteamOS Unlock ---
echo -e "${YELLOW}${BOLD}IMPORTANT NOTICE:${NC}"
echo -e "This script installs the Dial Daemon and System Services for SteamOS."
echo -n -e "${GREEN}Do you proceed? [y/N]: ${NC}"
read -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "\n${RED}Aborted.${NC}"; exit 0
fi

# Unlock SteamOS filesystem
log_info "Unlocking SteamOS read-only filesystem..."
steamos-readonly disable
log_success "Filesystem unlocked."

# --- Step 1: Cleanup ---
log_header "Step 1/4: Cleaning up old installations..."
systemctl stop $DIAL_SERVICE_NAME 2>/dev/null || true
systemctl disable $DIAL_SERVICE_NAME 2>/dev/null || true
rm -f $DIAL_SERVICE_PATH

rm -f "$DIAL_INSTALL_DIR/$DIAL_SCRIPT_NAME"
log_success "Cleaned."

# --- Step 2: Prerequisites ---
log_header "Step 2/4: Checking prerequisites..."
if ! python3 -c "import evdev" &> /dev/null; then
    log_info "Installing python-evdev..."
    pip install evdev --break-system-packages 2>/dev/null || pip install evdev
fi

mkdir -p /etc/modules-load.d
modprobe uinput
echo "uinput" > /etc/modules-load.d/zotac-uinput.conf
log_success "Prerequisites OK."

# --- Step 3: Install Dial Daemon (HIDRAW FIX) ---
log_header "Step 3/4: Installing Dial Daemon (Raw Access)..."
mkdir -p $DIAL_INSTALL_DIR

# 1. Udev Rule
cat > "/etc/udev/rules.d/99-zotac-zone.rules" <<EOF
KERNEL=="hidraw*", ATTRS{idVendor}=="1ee9", ATTRS{idProduct}=="1590", MODE="0666"
EOF
udevadm control --reload-rules && udevadm trigger

# 2. Generate Python Script (HIDRAW Based)
cat << 'EOF' > "$DIAL_INSTALL_DIR/$DIAL_SCRIPT_NAME"
#!/usr/bin/env python3
# Zotac Zone Dial Daemon (Raw HID + Backlight Fix)
import os
import sys
import glob
import time
import argparse
from evdev import UInput, ecodes as e

# --- ARGS ---
parser = argparse.ArgumentParser()
parser.add_argument("--left", default="brightness")
parser.add_argument("--right", default="volume")
args = parser.parse_args()

# --- CONSTANTS ---
VID = "00001EE9"
PID = "00001590"

# --- ACTION MAP ---
ACTIONS = {
    "volume":            {"type": "key", "up": e.KEY_VOLUMEUP, "down": e.KEY_VOLUMEDOWN},
    "brightness":        {"type": "backlight", "step": 5},
    "scroll":            {"type": "rel", "axis": e.REL_WHEEL, "up": 1, "down": -1},
    "scroll_inverted":   {"type": "rel", "axis": e.REL_WHEEL, "up": -1, "down": 1},
    "arrows_vertical":   {"type": "key", "up": e.KEY_UP, "down": e.KEY_DOWN},
    "arrows_horizontal": {"type": "key", "up": e.KEY_RIGHT, "down": e.KEY_LEFT},
    "media":             {"type": "key", "up": e.KEY_NEXTSONG, "down": e.KEY_PREVIOUSSONG},
    "page_scroll":       {"type": "key", "up": e.KEY_PAGEUP, "down": e.KEY_PAGEDOWN},
    "zoom":              {"type": "key", "up": e.KEY_ZOOMIN, "down": e.KEY_ZOOMOUT}, 
}

# --- HELPERS ---
def find_backlight():
    # Prefer amdgpu for handhelds
    paths = glob.glob("/sys/class/backlight/*")
    if not paths: return None
    paths.sort(key=lambda x: "amdgpu" not in x)
    return paths[0]

def set_backlight(path, direction, step_pct):
    try:
        mf = os.path.join(path, "max_brightness")
        vf = os.path.join(path, "brightness")
        with open(mf, "r") as f: max_v = int(f.read().strip())
        with open(vf, "r") as f: cur_v = int(f.read().strip())
        
        step = max(1, int(max_v * (step_pct / 100.0)))
        new_v = cur_v + step if direction == "up" else cur_v - step
        new_v = max(0, min(new_v, max_v))
        
        with open(vf, "w") as f: f.write(str(new_v))
    except Exception as e:
        print(f"Backlight Err: {e}")

def find_hidraw():
    for p in glob.glob("/sys/class/hidraw/hidraw*"):
        try:
            with open(os.path.join(p, "device/uevent"), "r") as f:
                c = f.read().upper()
                if f"HID_ID={VID}:{PID}" in c or (f"PRODUCT={VID}/{PID}" in c):
                    return f"/dev/{os.path.basename(p)}"
        except: continue
    return None

# --- MAIN ---
def main():
    print(f"Dial Daemon (Raw). L:{args.left} R:{args.right}")
    backlight = find_backlight()
    print(f"Backlight: {backlight}")
    
    # Setup UInput
    cap = {e.EV_KEY: [], e.EV_REL: [e.REL_WHEEL]}
    for a in ACTIONS.values():
        if a["type"] == "key": cap[e.EV_KEY].extend([a["up"], a["down"]])
        elif a["type"] == "rel": cap[e.EV_REL].append(a["axis"])
        
    try:
        ui = UInput(cap, name="Zotac Zone Virtual Dials")
    except:
        print("UInput Fail. Need root?")
        sys.exit(1)

    while True:
        dev_path = find_hidraw()
        if not dev_path:
            time.sleep(3)
            continue
            
        print(f"Reading {dev_path}...")
        try:
            with open(dev_path, "rb") as f:
                while True:
                    data = f.read(64)
                    if not data: break
                    if len(data) < 4: continue
                    
                    # Parse Report
                    # [0]=ReportID(03) [3]=Trigger
                    if data[0] != 0x03: continue
                    trig = data[3]
                    if trig == 0x00: continue
                    
                    # Decode
                    action_conf = None
                    direction = None
                    
                    if trig == 0x10: action_conf, direction = ACTIONS.get(args.left), "down"
                    elif trig == 0x08: action_conf, direction = ACTIONS.get(args.left), "up"
                    elif trig == 0x02: action_conf, direction = ACTIONS.get(args.right), "down"
                    elif trig == 0x01: action_conf, direction = ACTIONS.get(args.right), "up"
                    
                    if not action_conf: continue
                    
                    # Execute
                    atype = action_conf["type"]
                    if atype == "backlight" and backlight:
                        set_backlight(backlight, direction, action_conf["step"])
                    elif atype == "key":
                        k = action_conf[direction]
                        ui.write(e.EV_KEY, k, 1)
                        ui.write(e.EV_KEY, k, 0)
                        ui.syn()
                    elif atype == "rel":
                        ui.write(e.EV_REL, action_conf["axis"], action_conf[direction])
                        ui.syn()
                        
        except OSError:
            print("Device disconnected.")
            time.sleep(2)
        except Exception as err:
            print(f"Error: {err}")
            time.sleep(2)

if __name__ == "__main__":
    main()
EOF
chmod +x "$DIAL_INSTALL_DIR/$DIAL_SCRIPT_NAME"

# 3. Create Service
cat > "$DIAL_SERVICE_PATH" <<EOF
[Unit]
Description=Zotac Zone Dial Daemon
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $DIAL_INSTALL_DIR/$DIAL_SCRIPT_NAME --left brightness --right volume
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$DIAL_SERVICE_NAME" > /dev/null
log_success "Dial Daemon Installed (Raw HID)."

# --- Step 4: Launch Dials ---
log_header "Step 4/4: Starting Services..."
systemctl restart "$DIAL_SERVICE_NAME"
if systemctl is-active --quiet "$DIAL_SERVICE_NAME"; then
    log_success "Dial Service Running."
else
    log_warn "Dial Service failed start. Check logs."
fi

# Re-lock SteamOS filesystem
log_info "Restoring SteamOS read-only filesystem..."
steamos-readonly enable
log_success "Filesystem locked."

# --- Summary ---
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}${BOLD}             INSTALLATION COMPLETE!                         ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "   ${BOLD}Dial Service:${NC}   Active (Raw Access)"
echo -e "${GREEN}============================================================${NC}"

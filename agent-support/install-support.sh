#!/bin/bash
# ============================================================
# Agent Remote Support v4.4 — Installer
#
# One file. Run it, type your password, done.
#
# Usage:
#   sudo bash install-support.sh              # Install
#   sudo bash install-support.sh --uninstall  # Remove everything
#
# What it does:
#   1. Installs two support scripts (Enable / Disable)
#   2. Locks them down so they can't be tampered with
#   3. Allows running them without a password in the future
#   4. Creates desktop shortcuts for easy access
#
# Security model:
#   - Scripts are root-owned and immutable (chattr +i)
#     This prevents accidental modification. It does NOT
#     prevent a root user from deliberately removing the flag.
#   - Passwordless sudo verified by SHA256 hash of each script
#     If the script content changes, sudo will refuse to run it.
#   - Support sessions (Level 1/2) auto-expire after 24 hours
#   - Level 2+ sessions log all sudo input/output for audit
#   - Your sudo password is NOT stored or transmitted anywhere
#   - Tailscale installed via package manager with GPG verification
# ============================================================

set -euo pipefail

INSTALL_DIR="/opt/agent-support"
VERSION="4.4"
SESSION_TIMEOUT_HOURS=24
AUDIT_LOG_DIR="/var/log/agent-support"
AUDIT_LOG_FILE="$AUDIT_LOG_DIR/support.log"

# --- Support Access Configuration ---
# Tailscale auth keys are provided at support activation time.
# Do not bake live auth keys into this installer.
SSH_KEY_WILL="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ1DKUbxe7idA3EFzip8qEgvnDPW574l085HB9w7ijpe will2381@marc-laptop"
SSH_KEY_BROCK="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIQ2X6kZEbMeOBxaQMk9A1vBbNN+INE4YZzRJMqxuPKL brock@bedrock-agent"
SSH_KEY_WRENCH="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAMsS9ept3C7ITZqRxXrQeOu0u8CLnEFvVsTTOvpQtpk wrench@setup-Latitude-7320 support"

ensure_audit_log() {
    mkdir -p "$AUDIT_LOG_DIR"
    chmod 750 "$AUDIT_LOG_DIR"
    touch "$AUDIT_LOG_FILE"
    chmod 640 "$AUDIT_LOG_FILE"
}

write_audit_log() {
    local event="$1"
    shift || true
    ensure_audit_log
    printf '%s | installer | event=%s' "$(date -Iseconds)" "$event" >> "$AUDIT_LOG_FILE"
    while [ "$#" -gt 0 ]; do
        printf ' | %s' "$1" >> "$AUDIT_LOG_FILE"
        shift
    done
    printf '\n' >> "$AUDIT_LOG_FILE"
}

# Colors
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# --- Helper: find primary user ---
find_primary_user() {
    local user=""
    user=$(logname 2>/dev/null) || true
    if [ -z "$user" ] || [ "$user" = "root" ]; then
        user=$(who 2>/dev/null | head -1 | awk '{print $1}') || true
    fi
    if [ -z "$user" ] || [ "$user" = "root" ]; then
        user=$(getent passwd 1000 2>/dev/null | cut -d: -f1) || true
    fi
    if [ -z "$user" ]; then
        echo -e "${RED}Could not determine primary user. Specify with: PRIMARY_USER=username sudo bash $0${NC}" >&2
        exit 1
    fi
    echo "$user"
}

# --- Helper: generate agent ID ---
generate_agent_id() {
    local id
    id=$(cat /etc/machine-id 2>/dev/null | sha256sum | cut -c1-6 | tr '[:lower:]' '[:upper:]')
    [ -z "$id" ] && id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-6 | tr '[:lower:]' '[:upper:]')
    echo "$id"
}

# --- Helper: install Tailscale via package manager ---
install_tailscale() {
    # Try package manager first (with GPG key verification)
    if command -v apt-get &>/dev/null; then
        echo -e "${YELLOW}installing via apt...${NC}"
        mkdir -p --mode=0755 /usr/share/keyrings 2>/dev/null || true
        # Detect distro family (ubuntu vs debian vs other)
        local distro_family="ubuntu"
        local codename
        if [ -f /etc/os-release ]; then
            local os_id os_id_like
            os_id=$(. /etc/os-release && echo "$ID")
            os_id_like=$(. /etc/os-release && echo "$ID_LIKE")
            case "$os_id" in
                debian) distro_family="debian" ;;
                ubuntu) distro_family="ubuntu" ;;
                *)
                    # Check ubuntu FIRST — derivatives like Mint report
                    # ID_LIKE="ubuntu debian" and we need the ubuntu repo
                    if echo "$os_id_like" | grep -q ubuntu; then
                        distro_family="ubuntu"
                    elif echo "$os_id_like" | grep -q debian; then
                        distro_family="debian"
                    fi
                    ;;
            esac
        fi
        # For Ubuntu derivatives (Mint, Pop!_OS, etc.), use UBUNTU_CODENAME
        # which maps to the actual Ubuntu release, not the derivative's codename
        codename=""
        if [ "$distro_family" = "ubuntu" ] && [ -f /etc/os-release ]; then
            codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-}")
        fi
        # Fall back to lsb_release, then hardcoded defaults
        if [ -z "$codename" ]; then
            codename=$(lsb_release -cs 2>/dev/null || echo "")
        fi
        if [ -z "$codename" ]; then
            [ "$distro_family" = "ubuntu" ] && codename="noble" || codename="bookworm"
        fi
        if ! curl -fsSL "https://pkgs.tailscale.com/stable/${distro_family}/${codename}.noarmor.gpg" \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg; then
            return 1
        fi
        echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${distro_family} ${codename} main" \
            > /etc/apt/sources.list.d/tailscale.list
        apt-get update -qq 2>&1 | grep -v "^Hit\|^Get\|^Ign\|^Reading\|^Building" || true
        apt-get install -y tailscale
        return $?
    elif command -v dnf &>/dev/null; then
        echo -e "${YELLOW}installing via dnf...${NC}"
        dnf config-manager --add-repo https://pkgs.tailscale.com/stable/fedora/tailscale.repo 2>/dev/null
        dnf install -y tailscale 2>/dev/null
        return $?
    elif command -v pacman &>/dev/null; then
        echo -e "${YELLOW}installing via pacman...${NC}"
        pacman -Sy --noconfirm tailscale 2>/dev/null
        return $?
    fi
    return 1
}

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run with sudo:${NC}"
    echo "  sudo bash install-support.sh"
    exit 1
fi

# --- Uninstall mode ---
if [ "${1:-}" = "--uninstall" ]; then
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Agent Remote Support — Uninstall         ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo ""

    # Run support-off first if active
    if [ -f /var/lib/agent-support/session ]; then
        echo "Disabling active support session..."
        bash "$INSTALL_DIR/support-off.sh" --quiet 2>/dev/null || true
    fi

    echo -n "Removing scripts... "
    chattr -i "$INSTALL_DIR/support-on.sh" 2>/dev/null || true
    chattr -i "$INSTALL_DIR/support-off.sh" 2>/dev/null || true
    chattr -i "$INSTALL_DIR/agent-id" 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    echo "done"

    echo -n "Removing sudoers... "
    rm -f /etc/sudoers.d/agent-support /etc/sudoers.d/agent-support-diag
    echo "done"

    echo -n "Removing support user... "
    if id agent-support &>/dev/null; then
        pkill -u agent-support 2>/dev/null || true
        sleep 1
        userdel -r agent-support 2>/dev/null || true
    fi
    echo "done"

    echo -n "Removing timer... "
    systemctl stop agent-support-timeout.timer 2>/dev/null || true
    systemctl disable agent-support-timeout.timer 2>/dev/null || true
    rm -f /etc/systemd/system/agent-support-timeout.timer
    rm -f /etc/systemd/system/agent-support-timeout.service
    systemctl daemon-reload 2>/dev/null || true
    echo "done"

    PRIMARY_USER=$(find_primary_user)
    USER_HOME=$(getent passwd "$PRIMARY_USER" | cut -d: -f6)

    echo -n "Removing shortcuts... "
    rm -f "$USER_HOME/support-on.sh" "$USER_HOME/support-off.sh"
    rm -f "$USER_HOME/Desktop/Enable-Support.desktop" "$USER_HOME/Desktop/Disable-Support.desktop" 2>/dev/null || true
    rm -f /usr/share/applications/agent-support-enable.desktop /usr/share/applications/agent-support-disable.desktop 2>/dev/null || true
    echo "done"

    echo -n "Cleaning state... "
    rm -rf /var/lib/agent-support
    echo "done"

    echo -n "Removing audit log... "
    rm -rf "$AUDIT_LOG_DIR"
    echo "done"

    echo ""
    echo -e "${GREEN}  Agent Remote Support fully uninstalled.${NC}"
    echo ""
    exit 0
fi

# --- Generate Agent ID ---
AGENT_ID=$(generate_agent_id)
# Preserve existing ID if reinstalling
if [ -f "$INSTALL_DIR/agent-id" ]; then
    AGENT_ID=$(cat "$INSTALL_DIR/agent-id")
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Agent Remote Support — Installer v${VERSION}    ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "  Agent ID: ${CYAN}${AGENT_ID}${NC}"
echo ""

ensure_audit_log
write_audit_log "install_start" "version=$VERSION" "agent_id=$AGENT_ID"

# Step 1: Create support-on.sh
echo -n "Creating support scripts... "
mkdir -p "$INSTALL_DIR"

# Remove immutable flag if reinstalling
chattr -i "$INSTALL_DIR/support-on.sh" 2>/dev/null || true
chattr -i "$INSTALL_DIR/support-off.sh" 2>/dev/null || true
chattr -i "$INSTALL_DIR/agent-id" 2>/dev/null || true

# ---- BEGIN support-on.sh ----
cat > "$INSTALL_DIR/support-on.sh" << 'SUPPORT_ON_SCRIPT'
#!/bin/bash
set -euo pipefail
AGENT_ID=$(cat /opt/agent-support/agent-id 2>/dev/null || echo "UNKNOWN")
SSH_KEY_WILL="__SSH_KEY_WILL__"
SSH_KEY_BROCK="__SSH_KEY_BROCK__"
SSH_KEY_WRENCH="__SSH_KEY_WRENCH__"
SESSION_TIMEOUT_HOURS="__SESSION_TIMEOUT_HOURS__"
SUPPORT_MARKER="/var/lib/agent-support/session"
SUPPORT_USER="agent-support"
AUDIT_LOG_DIR="__AUDIT_LOG_DIR__"
AUDIT_LOG_FILE="__AUDIT_LOG_FILE__"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

ensure_audit_log() {
    mkdir -p "$AUDIT_LOG_DIR"
    chmod 750 "$AUDIT_LOG_DIR" 2>/dev/null || true
    touch "$AUDIT_LOG_FILE"
    chmod 640 "$AUDIT_LOG_FILE" 2>/dev/null || true
}

write_audit_log() {
    local event="$1"
    shift || true
    ensure_audit_log
    printf '%s | support-on | event=%s' "$(date -Iseconds)" "$event" >> "$AUDIT_LOG_FILE"
    while [ "$#" -gt 0 ]; do
        printf ' | %s' "$1" >> "$AUDIT_LOG_FILE"
        shift
    done
    printf '\n' >> "$AUDIT_LOG_FILE"
}

usage() {
    cat <<EOF
Usage:
  sudo support-on.sh [--support-key <tailscale-auth-key>]

Options:
  --support-key <key>   Tailscale auth key provided by Bedrock for support activation
  -h, --help            Show this help text
EOF
}

SUPPORT_KEY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --support-key)
            if [ $# -lt 2 ]; then
                echo -e "${RED}Missing value for --support-key${NC}"
                usage
                exit 1
            fi
            SUPPORT_KEY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            usage
            exit 1
            ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run with sudo:${NC}"; echo "  sudo support-on.sh"; exit 1
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Agent Remote Support                     ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "  Agent ID: ${CYAN}${AGENT_ID}${NC}"
echo ""
echo "  Choose a support level:"
echo ""
echo -e "  ${CYAN}1)${NC} Non-Admin Access"
echo -e "     Standard shell access for support review and triage."
echo -e "     ${GREEN}No sudo or administrative access.${NC}"
echo -e "     Auto-expires in ${SESSION_TIMEOUT_HOURS}h."
echo ""
echo -e "  ${CYAN}2)${NC} Full Support"
echo -e "     Secure shell access with full administrative access."
echo -e "     ${YELLOW}Changes and fixes are allowed while support is active.${NC}"
echo -e "     Auto-expires in ${SESSION_TIMEOUT_HOURS}h. All actions logged."
echo ""
echo -e "  ${CYAN}3)${NC} Ongoing Management"
echo -e "     Permanent connection for regular maintenance."
echo -e "     ${YELLOW}Access stays on until you disable it.${NC}"
echo ""
echo -e "  ${CYAN}0)${NC} Cancel"
echo ""
read -p "  Enter choice [1/2/3/0]: " -n 1 -r LEVEL
echo ""; echo ""

if [ "$LEVEL" = "0" ] || [ -z "$LEVEL" ]; then echo "Cancelled."; exit 0; fi
if [[ ! "$LEVEL" =~ ^[123]$ ]]; then echo -e "${RED}Invalid choice.${NC}"; exit 1; fi

declare -A LEVEL_NAME
LEVEL_NAME[1]="Non-Admin Access"; LEVEL_NAME[2]="Full Support"; LEVEL_NAME[3]="Ongoing Management"

if [ -z "$SUPPORT_KEY" ]; then
    echo "  Bedrock support requires a Tailscale auth key at activation time."
    echo "  Paste the support key exactly as provided by Bedrock."
    echo ""
    read -r -s -p "  Enter Bedrock support key: " SUPPORT_KEY
    echo ""
    echo ""
fi

if [ -z "$SUPPORT_KEY" ]; then
    echo -e "${RED}No support key provided. Cancelling.${NC}"
    exit 1
fi

write_audit_log "support_on_started" "agent_id=$AGENT_ID"
write_audit_log "level_selected" "level=$LEVEL" "level_name=${LEVEL_NAME[$LEVEL]}"

# Clean up previous session if upgrading
if [ -f "$SUPPORT_MARKER" ]; then
    CURRENT_LEVEL=$(grep "^LEVEL=" "$SUPPORT_MARKER" 2>/dev/null | head -1 | cut -d= -f2)
    if [ "${CURRENT_LEVEL:-}" = "$LEVEL" ]; then
        echo -e "${YELLOW}Level $LEVEL is already active.${NC}"; echo "Run support-off.sh to disconnect first."; exit 0
    fi
    echo -e "${YELLOW}Upgrading from Level ${CURRENT_LEVEL:-?} to Level $LEVEL...${NC}"
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    bash "$SCRIPT_DIR/support-off.sh" --quiet 2>/dev/null || true
fi

# Tailscale
echo -n "Checking Tailscale... "
if ! command -v tailscale &>/dev/null; then
    echo -e "${RED}not installed${NC}"
    echo -e "  ${YELLOW}Install Tailscale first: https://tailscale.com/download${NC}"
    echo -e "  ${YELLOW}Then run this script again.${NC}"
    exit 1
fi
echo -e "${GREEN}ok${NC}"

PREV_STATE="none"; PREV_TAILNET=""; RESTORE_ACTION="none"
OUR_TAILNET="upgradeya.com"
if tailscale status &>/dev/null; then
    PREV_STATE="connected"
    # Parse tailnet name: try python3, fall back to grep
    PREV_TAILNET=$(
        tailscale status --json 2>/dev/null | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('CurrentTailnet',{}).get('Name','unknown'))" \
            2>/dev/null \
        || tailscale status --json 2>/dev/null | grep -o '"MagicDNSSuffix":"[^"]*"' | head -1 | cut -d'"' -f4 \
        || echo "unknown"
    )
    if [ "$PREV_TAILNET" != "$OUR_TAILNET" ] && [ "$PREV_TAILNET" != "unknown" ]; then
        RESTORE_ACTION="manual_reauth"
        echo ""
        echo -e "  ${YELLOW}Tailscale is already connected to: ${PREV_TAILNET}${NC}"
        echo -e "  ${YELLOW}Enabling support will disconnect you from that network.${NC}"
        echo -e "  ${YELLOW}When support ends, you may need to re-authenticate to restore it.${NC}"
        echo -e "  ${YELLOW}Typical restore command: sudo tailscale up${NC}"
        echo ""
        read -p "  Continue? [Y/n] " -n 1 -r; echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then echo "Cancelled."; exit 0; fi
    elif [ "$PREV_TAILNET" = "$OUR_TAILNET" ]; then
        RESTORE_ACTION="return_to_support_tailnet"
    fi
fi

echo -n "Connecting to support network... "
TS_OUTPUT=$(tailscale up --authkey="$SUPPORT_KEY" --force-reauth --accept-risk=lose-ssh 2>&1)
TS_EXIT=$?
if [ $TS_EXIT -ne 0 ]; then
    write_audit_log "tailscale_connect_failed" "level=$LEVEL" "exit=$TS_EXIT"
    echo -e "${RED}failed${NC}"
    echo -e "  ${RED}$TS_OUTPUT${NC}"
    echo ""
    echo -e "  ${YELLOW}The support auth key may be invalid, expired, or already used.${NC}"
    echo -e "  ${YELLOW}Contact Bedrock for a fresh support key.${NC}"
    exit 1
fi
sleep 2
write_audit_log "tailscale_connected" "level=$LEVEL"
echo -e "${GREEN}connected${NC}"

echo -n "Ensuring connectivity... "
SUPPORT_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
if tailscale status &>/dev/null; then
    echo -e "${GREEN}ok (${SUPPORT_IP})${NC}"
else
    echo -e "${RED}warning: tailscale may not be fully connected${NC}"
fi

PRIMARY_USER=$(logname 2>/dev/null || true)
if [ -z "${PRIMARY_USER:-}" ] || [ "$PRIMARY_USER" = "root" ]; then
    PRIMARY_USER=$(who 2>/dev/null | head -1 | awk '{print $1}') || true
fi
if [ -z "${PRIMARY_USER:-}" ] || [ "$PRIMARY_USER" = "root" ]; then
    PRIMARY_USER=$(getent passwd 1000 2>/dev/null | cut -d: -f1) || true
fi
USER_HOME=$(getent passwd "$PRIMARY_USER" 2>/dev/null | cut -d: -f6)

# Create support user
echo -n "Setting up support user... "
if ! id "$SUPPORT_USER" &>/dev/null; then useradd -m -s /bin/bash "$SUPPORT_USER" 2>/dev/null; fi
SSH_DIR="/home/$SUPPORT_USER/.ssh"
mkdir -p "$SSH_DIR"
echo "$SSH_KEY_WILL" > "$SSH_DIR/authorized_keys"
echo "$SSH_KEY_BROCK" >> "$SSH_DIR/authorized_keys"
echo "$SSH_KEY_WRENCH" >> "$SSH_DIR/authorized_keys"
chmod 700 "$SSH_DIR"; chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$SUPPORT_USER:$SUPPORT_USER" "$SSH_DIR"
echo -e "${GREEN}done${NC}"
write_audit_log "support_user_ready" "user=$SUPPORT_USER"

# Configure access level with sudoers validation
echo -n "Configuring access... "
SUDOERS_FILE="/etc/sudoers.d/agent-support-diag"
rm -f "$SUDOERS_FILE"

if [ "$LEVEL" -eq 1 ]; then
    echo -e "${GREEN}done (Level 1, no sudo)${NC}"
    write_audit_log "access_configured" "level=$LEVEL" "sudo=none"
elif [ "$LEVEL" -ge 2 ]; then
    cat > "$SUDOERS_FILE" << SUDOERS
# Agent Remote Support — Level $LEVEL (Full Access)
# Created: $(date -Iseconds)
# All sudo commands are logged to /var/log/sudo-io/
Defaults:$SUPPORT_USER log_input, log_output, iolog_dir=/var/log/sudo-io/%{user}
$SUPPORT_USER ALL=(ALL) NOPASSWD: ALL
SUDOERS

    chmod 440 "$SUDOERS_FILE"
    chown root:root "$SUDOERS_FILE"
    if ! visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
        echo -e "${RED}sudoers validation failed — removing${NC}"
        rm -f "$SUDOERS_FILE"
        exit 1
    fi
    echo -e "${GREEN}done (Level $LEVEL)${NC}"
    write_audit_log "access_configured" "level=$LEVEL" "sudo=full" "sudo_iolog=/var/log/sudo-io"
fi

SSH_USER="$SUPPORT_USER"

echo -n "Checking SSH... "
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    echo -e "${GREEN}running${NC}"
else
    # Try to start existing SSH service
    if systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null; then
        echo -e "${GREEN}started${NC}"
    else
        # SSH server not installed — install it
        echo -e "${YELLOW}not installed, installing...${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq openssh-server 2>/dev/null
        elif command -v dnf &>/dev/null; then
            dnf install -y openssh-server 2>/dev/null
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm openssh 2>/dev/null
        fi
        systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
        if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
            echo -e "${GREEN}installed and running${NC}"
        else
            echo -e "${RED}failed to install SSH. Remote access may not work.${NC}"
        fi
    fi
fi

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    echo -n "Opening firewall... "
    ufw allow in on tailscale0 to any port 22 proto tcp comment 'Agent Remote Support' &>/dev/null || true
    echo -e "${GREEN}done${NC}"
    write_audit_log "firewall_updated" "rule=ssh_on_tailscale0"
fi

# Session timeout (Level 1/2 only)
if [ "$LEVEL" -lt 3 ]; then
    echo -n "Setting ${SESSION_TIMEOUT_HOURS}h auto-expire... "
    cat > /etc/systemd/system/agent-support-timeout.service << TIMER_SVC
[Unit]
Description=Agent Remote Support — Auto-expire session
[Service]
Type=oneshot
ExecStart=/opt/agent-support/support-off.sh --quiet
TIMER_SVC
    cat > /etc/systemd/system/agent-support-timeout.timer << TIMER_UNIT
[Unit]
Description=Agent Remote Support — Session timeout
[Timer]
OnActiveSec=${SESSION_TIMEOUT_HOURS}h
AccuracySec=1min
[Install]
WantedBy=timers.target
TIMER_UNIT
    systemctl daemon-reload
    systemctl enable --now agent-support-timeout.timer 2>/dev/null
    echo -e "${GREEN}done${NC}"
fi

# Save session state (parsed safely — never sourced)
mkdir -p /var/lib/agent-support
chmod 700 /var/lib/agent-support
cat > "$SUPPORT_MARKER" << EOF
STARTED=$(date -Iseconds)
AGENT_ID=$AGENT_ID
VERSION=__VERSION__
LEVEL=$LEVEL
TAILSCALE_IP=$SUPPORT_IP
SSH_USER=$SSH_USER
PRIMARY_USER=$PRIMARY_USER
PREVIOUS_STATE=$PREV_STATE
PREVIOUS_TAILNET=$PREV_TAILNET
RESTORE_ACTION=$RESTORE_ACTION
EOF
chmod 600 "$SUPPORT_MARKER"
write_audit_log "support_enabled" "level=$LEVEL" "ssh_user=$SSH_USER" "tailscale_ip=$SUPPORT_IP"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Support Active — ${LEVEL_NAME[$LEVEL]}$(printf '%*s' $((18 - ${#LEVEL_NAME[$LEVEL]})) '')${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "  Agent ID:    ${CYAN}${AGENT_ID}${NC}"
echo -e "  SSH command: ${GREEN}ssh ${SSH_USER}@${SUPPORT_IP}${NC}"
echo -e "  Audit log:   ${GREEN}${AUDIT_LOG_FILE}${NC}"
if [ "$LEVEL" -lt 3 ]; then
echo -e "  Expires in:  ${SESSION_TIMEOUT_HOURS} hours (auto)"
fi
echo ""
echo -e "  ${CYAN}Send the above to your admin.${NC}"
echo ""
echo -e "  ${YELLOW}─────────────────────────────────────────${NC}"
echo -e "  ${CYAN}Agent Support${NC}"
echo -e "  ${GREEN}bedrockadvisorygroup.com/agent-support/bedrock-mnm${NC}"
echo -e "  ${YELLOW}─────────────────────────────────────────${NC}"
echo ""
if [ "$LEVEL" -lt 3 ]; then echo -e "  To disconnect early: ${GREEN}sudo support-off.sh${NC}"; fi
if [ "$LEVEL" -eq 1 ]; then echo ""; echo -e "  Need more help? Run this script again"; echo -e "  and choose Level 2 for full support."; fi
echo ""
SUPPORT_ON_SCRIPT

# ---- BEGIN support-off.sh ----
cat > "$INSTALL_DIR/support-off.sh" << 'SUPPORT_OFF_SCRIPT'
#!/bin/bash
set -euo pipefail
SUPPORT_MARKER="/var/lib/agent-support/session"
SUPPORT_USER="agent-support"
AUDIT_LOG_DIR="__AUDIT_LOG_DIR__"
AUDIT_LOG_FILE="__AUDIT_LOG_FILE__"
QUIET=false
while [[ $# -gt 0 ]]; do case $1 in --quiet|-q) QUIET=true; shift ;; *) shift ;; esac; done
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

ensure_audit_log() {
    mkdir -p "$AUDIT_LOG_DIR"
    chmod 750 "$AUDIT_LOG_DIR" 2>/dev/null || true
    touch "$AUDIT_LOG_FILE"
    chmod 640 "$AUDIT_LOG_FILE" 2>/dev/null || true
}

write_audit_log() {
    local event="$1"
    shift || true
    ensure_audit_log
    printf '%s | support-off | event=%s' "$(date -Iseconds)" "$event" >> "$AUDIT_LOG_FILE"
    while [ "$#" -gt 0 ]; do
        printf ' | %s' "$1" >> "$AUDIT_LOG_FILE"
        shift
    done
    printf '\n' >> "$AUDIT_LOG_FILE"
}

if [ "$QUIET" = false ]; then
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Agent Remote Support — Disconnect        ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"; echo ""
fi

if [ "$EUID" -ne 0 ]; then echo -e "${RED}Please run with sudo${NC}"; exit 1; fi

# Parse marker safely (never source it)
LEVEL=0; PRIMARY_USER=""; PREV_STATE="none"; PREV_TAILNET=""; RESTORE_ACTION="none"
if [ -f "$SUPPORT_MARKER" ]; then
    LEVEL=$(grep "^LEVEL=" "$SUPPORT_MARKER" 2>/dev/null | head -1 | cut -d= -f2 || echo "0")
    PRIMARY_USER=$(grep "^PRIMARY_USER=" "$SUPPORT_MARKER" 2>/dev/null | head -1 | cut -d= -f2 || echo "")
    PREV_STATE=$(grep "^PREVIOUS_STATE=" "$SUPPORT_MARKER" 2>/dev/null | head -1 | cut -d= -f2 || echo "none")
    PREV_TAILNET=$(grep "^PREVIOUS_TAILNET=" "$SUPPORT_MARKER" 2>/dev/null | head -1 | cut -d= -f2 || echo "")
    RESTORE_ACTION=$(grep "^RESTORE_ACTION=" "$SUPPORT_MARKER" 2>/dev/null | head -1 | cut -d= -f2 || echo "none")
fi

write_audit_log "support_off_started" "level=${LEVEL:-0}" "previous_state=$PREV_STATE"

if [ "${LEVEL:-0}" -eq 0 ] && [ "$QUIET" = false ]; then
    echo -e "${YELLOW}No active support session found.${NC}"
    read -p "Clean up anyway? [y/N] " -n 1 -r; echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 0; fi
fi

# Stop session timeout timer
[ "$QUIET" = false ] && echo -n "Stopping timeout timer... "
systemctl stop agent-support-timeout.timer 2>/dev/null || true
systemctl disable agent-support-timeout.timer 2>/dev/null || true
[ "$QUIET" = false ] && echo -e "${GREEN}done${NC}"

# Disconnect Tailscale
[ "$QUIET" = false ] && echo -n "Disconnecting from support network... "
tailscale down 2>/dev/null || true
[ "$QUIET" = false ] && echo -e "${GREEN}done${NC}"
write_audit_log "tailscale_disconnected"

# Remove support user and all associated access
if id "$SUPPORT_USER" &>/dev/null; then
    [ "$QUIET" = false ] && echo -n "Removing support user... "
    pkill -u "$SUPPORT_USER" 2>/dev/null || true
    sleep 1
    userdel -r "$SUPPORT_USER" 2>/dev/null || true
    [ "$QUIET" = false ] && echo -e "${GREEN}removed${NC}"
fi
write_audit_log "support_user_removed" "user=$SUPPORT_USER"

# Remove sudoers and access rules
[ "$QUIET" = false ] && echo -n "Removing access rules... "
rm -f /etc/sudoers.d/agent-support-diag
[ "$QUIET" = false ] && echo -e "${GREEN}done${NC}"
write_audit_log "access_rules_removed"

# Clean SSH keys from primary user (safety net)
if [ -n "$PRIMARY_USER" ]; then
    USER_HOME=$(getent passwd "$PRIMARY_USER" 2>/dev/null | cut -d: -f6)
    AUTH_KEYS="${USER_HOME:-/dev/null}/.ssh/authorized_keys"
    if [ -f "$AUTH_KEYS" ]; then
        [ "$QUIET" = false ] && echo -n "Removing support SSH keys... "
        sed -i '/will2381@marc-laptop/d' "$AUTH_KEYS" 2>/dev/null
        sed -i '/brock@bedrock-agent/d' "$AUTH_KEYS" 2>/dev/null
        sed -i '/wrench@setup-Latitude-7320 support/d' "$AUTH_KEYS" 2>/dev/null
        [ "$QUIET" = false ] && echo -e "${GREEN}removed${NC}"
    fi
else
    # Scan all users as fallback
    for user_home in /home/*; do
        auth_file="$user_home/.ssh/authorized_keys"
        if [ -f "$auth_file" ]; then
            sed -i '/will2381@marc-laptop/d' "$auth_file" 2>/dev/null
            sed -i '/brock@bedrock-agent/d' "$auth_file" 2>/dev/null
            sed -i '/wrench@setup-Latitude-7320 support/d' "$auth_file" 2>/dev/null
        fi
    done
fi

# Firewall cleanup
[ "$QUIET" = false ] && echo -n "Cleaning up firewall... "
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Agent Remote Support"; then
    ufw delete allow in on tailscale0 to any port 22 proto tcp comment 'Agent Remote Support' &>/dev/null || true
    [ "$QUIET" = false ] && echo -e "${GREEN}removed support SSH rule${NC}"
    write_audit_log "firewall_rule_removed" "rule=ssh_on_tailscale0"
else
    [ "$QUIET" = false ] && echo -e "${GREEN}no changes needed${NC}"
fi

# Clean state (preserve agent-id and installed scripts)
rm -f "$SUPPORT_MARKER"
rm -rf /var/lib/agent-support
write_audit_log "support_disabled"

if [ "$QUIET" = false ]; then
    echo ""; echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Agent Remote Support Disconnected         ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"; echo ""
    echo "  Disconnected from support network"
    echo "  SSH keys removed"
    echo "  Support user removed"
    echo "  Access rules removed"
    echo "  Timeout timer stopped"
    if [ "$RESTORE_ACTION" = "manual_reauth" ]; then
        echo ""
        echo -e "  ${YELLOW}Previous Tailscale network: ${PREV_TAILNET:-unknown}${NC}"
        echo -e "  ${YELLOW}Restore is not automatic, to avoid reconnecting to the wrong network.${NC}"
        echo -e "  ${YELLOW}If you want it back, run: sudo tailscale up${NC}"
    elif [ "$RESTORE_ACTION" = "return_to_support_tailnet" ]; then
        echo ""
        echo -e "  ${YELLOW}This machine was already on the support tailnet before this session.${NC}"
        echo -e "  ${YELLOW}If you want to reconnect, run: sudo tailscale up${NC}"
    fi
    echo ""
    echo "  Audit log: $AUDIT_LOG_FILE"
    echo "  View it with: sudo less $AUDIT_LOG_FILE"
    if [ -t 0 ] && [ -t 1 ]; then
        echo ""
        read -p "  View the audit log now? [y/N] " -n 1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if command -v less &>/dev/null; then
                less "$AUDIT_LOG_FILE"
            else
                cat "$AUDIT_LOG_FILE"
            fi
        fi
    fi
    echo "  Your machine is no longer accessible remotely."
    echo ""
fi
SUPPORT_OFF_SCRIPT

# Inject configuration into support-on.sh
sed -i "s|__SSH_KEY_WILL__|${SSH_KEY_WILL}|g" "$INSTALL_DIR/support-on.sh"
sed -i "s|__SSH_KEY_BROCK__|${SSH_KEY_BROCK}|g" "$INSTALL_DIR/support-on.sh"
sed -i "s|__SSH_KEY_WRENCH__|${SSH_KEY_WRENCH}|g" "$INSTALL_DIR/support-on.sh"
sed -i "s|__SESSION_TIMEOUT_HOURS__|${SESSION_TIMEOUT_HOURS}|g" "$INSTALL_DIR/support-on.sh"
sed -i "s|__AUDIT_LOG_DIR__|${AUDIT_LOG_DIR}|g" "$INSTALL_DIR/support-on.sh"
sed -i "s|__AUDIT_LOG_FILE__|${AUDIT_LOG_FILE}|g" "$INSTALL_DIR/support-on.sh"
sed -i "s|__VERSION__|${VERSION}|g" "$INSTALL_DIR/support-on.sh"
sed -i "s|__AUDIT_LOG_DIR__|${AUDIT_LOG_DIR}|g" "$INSTALL_DIR/support-off.sh"
sed -i "s|__AUDIT_LOG_FILE__|${AUDIT_LOG_FILE}|g" "$INSTALL_DIR/support-off.sh"

echo "done"

# Step 2: Persist agent ID
echo -n "Setting agent ID... "
echo "$AGENT_ID" > "$INSTALL_DIR/agent-id"
echo "done"

# Step 3: Set permissions
echo -n "Locking down scripts... "
chown root:root "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"
for f in support-on.sh support-off.sh agent-id; do
    chown root:root "$INSTALL_DIR/$f"
done
chmod 700 "$INSTALL_DIR/support-on.sh" "$INSTALL_DIR/support-off.sh"
chmod 444 "$INSTALL_DIR/agent-id"
chattr +i "$INSTALL_DIR/support-on.sh" 2>/dev/null || true
chattr +i "$INSTALL_DIR/support-off.sh" 2>/dev/null || true
chattr +i "$INSTALL_DIR/agent-id" 2>/dev/null || true
echo "done"

# Step 4: Passwordless sudo with digest verification
PRIMARY_USER=$(find_primary_user)
USER_HOME=$(getent passwd "$PRIMARY_USER" | cut -d: -f6)

echo -n "Configuring sudo access... "
ON_HASH=$(sha256sum "$INSTALL_DIR/support-on.sh" | awk '{print $1}')
OFF_HASH=$(sha256sum "$INSTALL_DIR/support-off.sh" | awk '{print $1}')

SUDOERS_INSTALL="/etc/sudoers.d/agent-support"
cat > "$SUDOERS_INSTALL" << EOF
# Agent Remote Support v${VERSION} — passwordless sudo for support scripts only
# Scripts verified by SHA256 digest — modified scripts will be rejected
# Installed: $(date -Iseconds)
# Agent ID: ${AGENT_ID}
# Owner: ${PRIMARY_USER}
${PRIMARY_USER} ALL=(root) NOPASSWD: sha256:${ON_HASH} $INSTALL_DIR/support-on.sh, sha256:${OFF_HASH} $INSTALL_DIR/support-off.sh
EOF
chmod 440 "$SUDOERS_INSTALL"
chown root:root "$SUDOERS_INSTALL"

if visudo -c -f "$SUDOERS_INSTALL" &>/dev/null; then echo "done"
else
    echo -e "${RED}WARNING: sudoers validation failed — removing${NC}"
    rm -f "$SUDOERS_INSTALL"
    exit 1
fi
write_audit_log "install_sudo_configured" "sudoers=$SUDOERS_INSTALL"

# Step 5: Install Tailscale if missing
if ! command -v tailscale &>/dev/null; then
    echo -n "Installing Tailscale... "
    if ! install_tailscale; then
        echo -e "${YELLOW}Package manager install failed.${NC}"
        echo -e "${YELLOW}Please install Tailscale manually: https://tailscale.com/download${NC}"
        echo -e "${YELLOW}Then run the installer again.${NC}"
        # Don't fail the install — scripts are in place, just need Tailscale
    else
        echo -e "${GREEN}done${NC}"
    fi
    systemctl enable --now tailscaled 2>/dev/null || true
else
    echo "Tailscale: already installed"
fi

# Step 6: App menu entries (always trusted — no "run anyway" warning)

echo -n "Creating app menu entries... "
cat > /usr/share/applications/agent-support-enable.desktop << EOF
[Desktop Entry]
Name=Enable Remote Support
Comment=Connect to support for assistance
Exec=bash -c 'sudo $INSTALL_DIR/support-on.sh; sleep 1; read -p "Press Enter to close..."'
Icon=system-help
Terminal=true
Type=Application
Categories=System;
Keywords=support;remote;agent;
EOF
cat > /usr/share/applications/agent-support-disable.desktop << EOF
[Desktop Entry]
Name=Disable Remote Support
Comment=Disconnect from support
Exec=bash -c 'sudo $INSTALL_DIR/support-off.sh; read -p "Press Enter to close..."'
Icon=system-lock-screen
Terminal=true
Type=Application
Categories=System;
Keywords=support;remote;agent;
EOF
echo "done"

# Step 6b: Desktop icons (best-effort trust marking)
DESKTOP_DIR="$USER_HOME/Desktop"
if [ -d "$DESKTOP_DIR" ]; then
    echo -n "Creating desktop shortcuts... "
    cp /usr/share/applications/agent-support-enable.desktop "$DESKTOP_DIR/Enable-Support.desktop"
    cp /usr/share/applications/agent-support-disable.desktop "$DESKTOP_DIR/Disable-Support.desktop"
    chmod +x "$DESKTOP_DIR/Enable-Support.desktop" "$DESKTOP_DIR/Disable-Support.desktop"
    chown "$PRIMARY_USER:$PRIMARY_USER" "$DESKTOP_DIR/Enable-Support.desktop" "$DESKTOP_DIR/Disable-Support.desktop"
    # Try to mark as trusted (DE-specific, may not work on all desktops)
    sudo -u "$PRIMARY_USER" gio set "$DESKTOP_DIR/Enable-Support.desktop" metadata::trusted true 2>/dev/null || true
    sudo -u "$PRIMARY_USER" gio set "$DESKTOP_DIR/Disable-Support.desktop" metadata::trusted true 2>/dev/null || true
    echo "done"
fi

# Step 7: Home directory symlinks
echo -n "Creating home shortcuts... "
ln -sf "$INSTALL_DIR/support-on.sh" "$USER_HOME/support-on.sh"
ln -sf "$INSTALL_DIR/support-off.sh" "$USER_HOME/support-off.sh"
chown -h "$PRIMARY_USER:$PRIMARY_USER" "$USER_HOME/support-on.sh" "$USER_HOME/support-off.sh"
echo "done"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Agent Remote Support v${VERSION} Installed       ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo "  Agent ID:   $AGENT_ID"
echo "  Version:    $VERSION"
echo "  Audit log:  $AUDIT_LOG_FILE"
echo "  Scripts:    $INSTALL_DIR/ (root-owned, immutable)"
echo "  Sudo:       passwordless, digest-verified"
echo "  User:       $PRIMARY_USER"
echo "  Timeout:    Level 1/2 auto-expire in ${SESSION_TIMEOUT_HOURS}h"
echo ""
echo "  Enable support:"
echo "    Search 'Support' in app menu (always works)"
echo "    Double-click 'Enable Remote Support' on desktop"
echo "    Or run: sudo ~/support-on.sh"
echo "    Optional: sudo ~/support-on.sh --support-key '<key from Bedrock>'"
echo ""
echo "  Uninstall:"
echo "    sudo bash install-support.sh --uninstall"
echo ""
echo "  Security:"
echo "    Scripts are root-owned and locked (chattr +i)"
echo "    Sudo verifies SHA256 hash before execution"
echo "    Level 2+ sessions log all sudo I/O to /var/log/sudo-io/"
echo "    Level 1/2 sessions auto-expire after ${SESSION_TIMEOUT_HOURS} hours"
echo ""

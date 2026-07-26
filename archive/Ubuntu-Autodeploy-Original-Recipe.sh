#!/bin/bash

# Ubuntu Security Tools Installation Script
# This script installs various security analysis tools on Ubuntu
# Tools: nmap, ncat, ping, binwalk, impacket, obsidian, smbclient, 
#        netexec, certipy, dnstool, i3, hashcat, java, zsh + oh-my-zsh, 
#        kitty, polybar, proxychains, net-tools, responder

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_error() {
    echo -e "${RED}[!]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[*]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root (use sudo)"
   exit 1
fi

print_status "Starting security tools installation..."

# Update system
print_status "Updating package lists..."
apt update

print_status "Upgrading existing packages..."
apt upgrade -y

# Install essential build tools and dependencies
print_status "Installing essential dependencies..."
apt install -y \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    pipx \
    git \
    curl \
    wget \
    libssl-dev \
    libffi-dev \
    python3-dev \
    python3-setuptools \
    libpcap-dev \
    libgmp3-dev \
    libxml2-dev \
    libxslt1-dev \
    zlib1g-dev \
    ocl-icd-libopencl1 \
    opencl-headers \
    clinfo \
    fonts-powerline \
    fonts-font-awesome \
    tmux \
    ncat \
    nmap \
    iputils-ping \
    binwalk \
    smbclient \
    dnsutils \
    default-jre \
    openjdk-8-jre \
    dnsrecon \
    python3-ldapdomaindump \
    adcli \
    nbtscan \
    python3-certipy \
    proxychains4 \
    net-tools

# 12. Install Python-based tools
print_status "Setting up Python environment for security tools..."

# Create symbolic links for Python tools if needed
print_status "Creating symbolic links for Python tools..."

# Determine the correct user and paths
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    USER_LOCAL_BIN="$USER_HOME/.local/bin"
else
    USER_LOCAL_BIN="$HOME/.local/bin"
fi

# Check if pipx tools were installed and create system-wide symlinks
if [ -d "$USER_LOCAL_BIN" ]; then
    print_status "Found pipx installation directory: $USER_LOCAL_BIN"
    
    # Create symlinks for commonly used tools
    for tool in netexec nxc nxcdb; do
        if [ -f "$USER_LOCAL_BIN/$tool" ]; then
            ln -sf "$USER_LOCAL_BIN/$tool" /usr/local/bin/
            print_status "Created system-wide symlink for $tool"
        fi
    done
    
    # Create symlinks for impacket tools
    for script in $(find "$USER_LOCAL_BIN" -name "*impacket*" -o -name "Get*" -o -name "psexec*" -o -name "smbexec*" -o -name "wmiexec*" -o -name "secretsdump*" -o -name "ntlmrelayx*" -o -name "smbserver*" -o -name "ticketer*" -o -name "mimikatz*" -o -name "goldenPac*" -o -name "lookupsid*" -o -name "rpcdump*" -o -name "samrdump*" -o -name "reg*" -o -name "atexec*" -o -name "dcomexec*" 2>/dev/null); do
        if [ -f "$script" ] && [ -x "$script" ]; then
            script_name=$(basename "$script")
            if [ ! -f "/usr/local/bin/$script_name" ]; then
                ln -sf "$script" /usr/local/bin/
                print_status "Created system-wide symlink for $script_name"
            fi
        fi
    done
else
    print_warning "Could not locate pipx installation directory"
fi

# Install pipx tools as the actual user (not root)
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    
    # Install Rust for the user first (required for NetExec)
    print_status "Installing Rust for user $SUDO_USER (required for NetExec)..."
    su - "$SUDO_USER" -c "
        if ! command -v rustc &> /dev/null; then
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            source ~/.cargo/env
        fi
    " || print_warning "Failed to install Rust for user"
    
    # Ensure pipx is available for the user
    print_status "Setting up pipx for user $SUDO_USER..."
    su - "$SUDO_USER" -c "
        python3 -m pip install --user pipx
        python3 -m pipx ensurepath
    " 2>/dev/null || print_warning "Failed to setup pipx for user"
    
    # Install impacket via pipx as user
    print_status "Installing impacket via pipx for user $SUDO_USER..."
    su - "$SUDO_USER" -c "
        source ~/.cargo/env 2>/dev/null || true
        python3 -m pipx install impacket
    " || print_warning "Failed to install impacket via pipx"
    
    # Install netexec via pipx as user
    print_status "Installing netexec via pipx for user $SUDO_USER..."
    su - "$SUDO_USER" -c "
        source ~/.cargo/env 2>/dev/null || true
        python3 -m pipx install git+https://github.com/Pennyw0rth/NetExec
    " || {
        print_warning "Failed to install netexec from GitHub for user $SUDO_USER"
        print_warning "This may be due to missing dependencies or Rust installation issues"
    }
    
    print_status "Pipx installations completed for user $SUDO_USER"
else
    print_warning "No SUDO_USER detected, installing pipx tools as root (may not be accessible to regular users)"
    
    # Fallback: install as root if no sudo user detected
    if ! command -v rustc &> /dev/null; then
        print_warning "Rust not found, installing Rust (required for NetExec)..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env" 2>/dev/null || true
    fi
    
    pipx install impacket || print_warning "Failed to install impacket via pipx"
    pipx install git+https://github.com/Pennyw0rth/NetExec || print_warning "Failed to install netexec via pipx"
fi

# Create dedicated Python environment for additional security tools
print_status "Creating dedicated Python environment for advanced security tools..."
SECURITY_VENV="/opt/security-tools-venv"
python3 -m venv "$SECURITY_VENV"

# Set proper ownership for the virtual environment
if [ -n "$SUDO_USER" ]; then
    chown -R "$SUDO_USER:$SUDO_USER" "$SECURITY_VENV"
    print_status "Set ownership of virtual environment to $SUDO_USER"
fi

# Activate the virtual environment for the rest of the installations
source "$SECURITY_VENV/bin/activate"

# Upgrade pip in the virtual environment
print_status "Upgrading pip in security tools environment..."
pip install --upgrade pip

# Install Python packages in the virtual environment
print_status "Installing Python packages in security environment..."
pip install netifaces
pip install aioquic

# Try to install pyrebase4 but don't fail if it doesn't work
print_status "Attempting to install pyrebase4..."
pip install pyrebase4 || {
    print_warning "Failed to install pyrebase4, continuing without it..."
}

# Install impacket from source (for latest features)
print_status "Installing impacket from source in security environment..."
cd /tmp
if [ -d "impacket" ]; then
    rm -rf impacket
fi
git clone https://github.com/fortra/impacket.git
cd impacket
pip install .
cd ..
print_status "Impacket installed from source"

# Install responder from source
print_status "Installing Responder from source..."
cd /tmp
if [ -d "Responder" ]; then
    rm -rf Responder
fi
git clone https://github.com/lgandx/Responder.git
cd Responder
pip install -r requirements.txt
# Install responder to the virtual environment
cp -r . "$SECURITY_VENV/responder"
chmod +x "$SECURITY_VENV/responder/Responder.py"
cd ..
print_status "Responder installed from source"

# Install certipy in the virtual environment (in addition to apt version)
print_status "Installing certipy-ad in security environment..."
pip install certipy-ad

# Deactivate virtual environment
deactivate

# Create wrapper scripts for virtual environment tools
print_status "Creating wrapper scripts for security tools..."
mkdir -p /usr/local/bin

# Create impacket wrapper scripts for venv version
for script in $(find "$SECURITY_VENV/bin" -name "*impacket*" -o -name "Get*" -o -name "add*" -o -name "atexec*" -o -name "dcom*" -o -name "dpapi*" -o -name "find*" -o -name "get*" -o -name "golden*" -o -name "karmaSMB*" -o -name "kint*" -o -name "lookupsid*" -o -name "mimikatz*" -o -name "mqtt*" -o -name "mssql*" -o -name "net*" -o -name "nmb*" -o -name "ntfs*" -o -name "ntlm*" -o -name "ping*" -o -name "psexec*" -o -name "raiseChild*" -o -name "rdp*" -o -name "reg*" -o -name "rpcdump*" -o -name "rpc*" -o -name "sambaPipe*" -o -name "samr*" -o -name "secret*" -o -name "service*" -o -name "smbclient*" -o -name "smbexec*" -o -name "smbpasswd*" -o -name "smbserver*" -o -name "sniff*" -o -name "split*" -o -name "ticketer*" -o -name "tick*" -o -name "wmi*" 2>/dev/null); do
    if [ -f "$script" ] && [ -x "$script" ]; then
        script_name=$(basename "$script")
        # Create venv version with -venv suffix to avoid conflicts
        cat > "/usr/local/bin/$script_name-venv" << EOF
#!/bin/bash
source "$SECURITY_VENV/bin/activate"
exec "$script" "\$@"
EOF
        chmod +x "/usr/local/bin/$script_name-venv"
    fi
done

# Create responder wrapper
cat > "/usr/local/bin/responder" << EOF
#!/bin/bash
source "$SECURITY_VENV/bin/activate"
cd "$SECURITY_VENV/responder"
exec python3 Responder.py "\$@"
EOF
chmod +x "/usr/local/bin/responder"

# Create certipy wrapper (for the venv version)
cat > "/usr/local/bin/certipy-venv" << EOF
#!/bin/bash
source "$SECURITY_VENV/bin/activate"
exec certipy "\$@"
EOF
chmod +x "/usr/local/bin/certipy-venv"

# 6. Install hashcat
print_status "Installing hashcat..."
apt install -y hashcat || {
    print_warning "Hashcat not found in repositories, installing from source..."
    # Install hashcat from source as fallback
    cd /tmp
    git clone https://github.com/hashcat/hashcat.git
    cd hashcat
    make
    make install
    cd ..
    rm -rf hashcat
}

# 7. Install DNS enumeration tools
print_status "Installing DNS enumeration tools..."
# Install dnsrecon via pip
python3 -m pip install dnsrecon || print_warning "Failed to install dnsrecon"

# Install dnsenum manually
print_status "Installing dnsenum..."
cd /tmp
git clone https://github.com/fwaeytens/dnsenum.git || print_warning "Failed to clone dnsenum"
if [ -d "dnsenum" ]; then
    cd dnsenum
    chmod +x dnsenum.pl
    cp dnsenum.pl /usr/local/bin/dnsenum
    cd ..
    rm -rf dnsenum
fi

# 8. Install i3 window manager
print_status "Installing i3 window manager..."
apt install -y i3 i3status i3lock xss-lock dmenu

# 9. Install polybar
print_status "Installing polybar..."
apt install -y polybar

# Create basic polybar config
print_status "Configuring polybar..."
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    POLYBAR_CONFIG_DIR="$USER_HOME/.config/polybar"
    mkdir -p "$POLYBAR_CONFIG_DIR"
    
    # Create launch script
    cat > "$POLYBAR_CONFIG_DIR/launch.sh" << 'EOF'
#!/bin/bash

# Terminate already running bar instances
killall -q polybar

# Wait until the processes have been shut down
while pgrep -u $UID -x polybar >/dev/null; do sleep 1; done

# Launch polybar
polybar main &

echo "Polybar launched..."
EOF
    chmod +x "$POLYBAR_CONFIG_DIR/launch.sh"
    
    # Create basic polybar config
    cat > "$POLYBAR_CONFIG_DIR/config.ini" << 'EOF'
[colors]
background = #282A2E
background-alt = #373B41
foreground = #C5C8C6
primary = #F0C674
secondary = #8ABEB7
alert = #A54242
disabled = #707880

[bar/main]
width = 100%
height = 24pt
radius = 0

background = ${colors.background}
foreground = ${colors.foreground}

line-size = 3pt

border-size = 0
border-color = #00000000

padding-left = 0
padding-right = 1

module-margin = 1

separator = |
separator-foreground = ${colors.disabled}

font-0 = monospace;2
font-1 = Font Awesome 6 Free:pixelsize=12;2
font-2 = Font Awesome 6 Free Solid:pixelsize=12;2
font-3 = Font Awesome 6 Brands:pixelsize=12;2

modules-left = i3 xwindow
modules-center = date
modules-right = network network-wireless cpu memory battery

cursor-click = pointer
cursor-scroll = ns-resize

enable-ipc = true

[module/i3]
type = internal/i3
pin-workspaces = true
show-urgent = true
strip-wsnumbers = true
index-sort = true

format = <label-state> <label-mode>

label-focused = %index%
label-focused-background = ${colors.background-alt}
label-focused-underline= ${colors.primary}
label-focused-padding = 1

label-unfocused = %index%
label-unfocused-padding = 1

label-visible = %index%
label-visible-underline = ${colors.secondary}
label-visible-padding = 1

label-urgent = %index%
label-urgent-background = ${colors.alert}
label-urgent-padding = 1

[module/xwindow]
type = internal/xwindow
label = %title:0:60:...%

[module/cpu]
type = internal/cpu
interval = 2
format-prefix = "CPU "
format-prefix-foreground = ${colors.primary}
label = %percentage:2%%

[module/memory]
type = internal/memory
interval = 2
format-prefix = "MEM "
format-prefix-foreground = ${colors.primary}
label = %percentage_used:2%%

[module/network]
type = internal/network
interface-type = wired
interval = 3.0

format-connected = <label-connected>
format-connected-prefix = "NET "
format-connected-prefix-foreground = ${colors.primary}
label-connected = %ifname% %local_ip%

format-disconnected = <label-disconnected>
label-disconnected = disconnected
label-disconnected-foreground = ${colors.disabled}

[module/network-wireless]
type = internal/network
interface-type = wireless
interval = 3.0

format-connected = <label-connected>
format-connected-prefix = "WIFI "
format-connected-prefix-foreground = ${colors.primary}
label-connected = %essid% %local_ip%

format-disconnected = <label-disconnected>
label-disconnected = no wifi
label-disconnected-foreground = ${colors.disabled}

[module/battery]
type = internal/battery
battery = BAT0
adapter = AC
full-at = 98

format-charging = <label-charging>
format-charging-prefix = "BAT+ "
format-charging-prefix-foreground = ${colors.secondary}
label-charging = %percentage%%

format-discharging = <label-discharging>
format-discharging-prefix = "BAT "
format-discharging-prefix-foreground = ${colors.primary}
label-discharging = %percentage%%

format-full-prefix = "FULL "
format-full-prefix-foreground = ${colors.secondary}
label-full = %percentage%%

[module/date]
type = internal/date
interval = 1

date = %Y-%m-%d %H:%M:%S
date-alt = %A, %B %d, %Y %H:%M:%S

label = %date%
label-foreground = ${colors.primary}

[settings]
screenchange-reload = true
pseudo-transparency = false
EOF
    
    # Update i3 config to use polybar instead of i3status
    USER_I3_CONFIG="$USER_HOME/.config/i3/config"
    if [ -f "$USER_I3_CONFIG" ]; then
        # Comment out i3bar section
        sed -i '/^bar {/,/^}/ s/^/#/' "$USER_I3_CONFIG"
        
        # Add polybar launch command
        if ! grep -q "polybar/launch.sh" "$USER_I3_CONFIG"; then
            echo ""
echo "=== Troubleshooting ==="
echo "If tools are not found after restarting terminal:"
echo "1. Check pipx installations: pipx list"
echo "2. Check PATH: echo \$PATH | grep -E 'local|snap|opt'"
echo "3. Manual PATH fix: source ~/.zshrc"
echo "4. Check tool locations:"
echo "   ls -la ~/.local/bin/"
echo "   ls -la /snap/bin/"
echo "   ls -la /opt/security-tools-venv/bin/"
echo "5. If still broken, reinstall as user:"
echo "   pipx install git+https://github.com/Pennyw0rth/NetExec"
echo "   pipx install impacket"
echo "6. For snap apps: snap list" >> "$USER_I3_CONFIG"
            echo "# Launch polybar" >> "$USER_I3_CONFIG"
            echo "exec_always --no-startup-id \$HOME/.config/polybar/launch.sh" >> "$USER_I3_CONFIG"
        fi
    else
        # If i3 config doesn't exist yet, make sure it will launch polybar when created
        mkdir -p "$USER_HOME/.config/i3"
        echo "# Launch polybar" > "$USER_HOME/.config/i3/polybar-autostart"
        echo "exec_always --no-startup-id \$HOME/.config/polybar/launch.sh" >> "$USER_HOME/.config/i3/polybar-autostart"
        chown -R "$SUDO_USER:$SUDO_USER" "$USER_HOME/.config/i3"
    fi
    
    chown -R "$SUDO_USER:$SUDO_USER" "$POLYBAR_CONFIG_DIR"
fi

# 10. Install zsh and make it default shell
print_status "Installing zsh..."
apt install -y zsh

# Set zsh as default shell for root and current sudo user
print_status "Setting zsh as default shell..."
chsh -s /usr/bin/zsh
if [ -n "$SUDO_USER" ]; then
    chsh -s /usr/bin/zsh "$SUDO_USER"
    print_status "Set zsh as default shell for $SUDO_USER"
fi

# Install Oh My Zsh
print_status "Installing Oh My Zsh..."
# Function to install Oh My Zsh for a specific user
install_oh_my_zsh() {
    local USER_NAME=$1
    local USER_HOME=$2
    
    if [ -d "$USER_HOME/.oh-my-zsh" ]; then
        print_warning "Oh My Zsh already installed for $USER_NAME"
        return
    fi
    
    # Download and install Oh My Zsh non-interactively
    su - "$USER_NAME" -c "
        export RUNZSH=no
        export CHSH=no
        export KEEP_ZSHRC=yes
        sh -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\" || \
        sh -c \"\$(wget -qO- https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\"
    " || {
        print_warning "Failed to install Oh My Zsh for $USER_NAME, trying alternative method..."
        # Alternative method: clone directly
        git clone https://github.com/ohmyzsh/ohmyzsh.git "$USER_HOME/.oh-my-zsh"
        cp "$USER_HOME/.oh-my-zsh/templates/zshrc.zsh-template" "$USER_HOME/.zshrc"
        chown -R "$USER_NAME:$USER_NAME" "$USER_HOME/.oh-my-zsh" "$USER_HOME/.zshrc"
    }
    
    # Configure .zshrc with useful plugins and theme
    if [ -f "$USER_HOME/.zshrc" ]; then
        # Backup original
        cp "$USER_HOME/.zshrc" "$USER_HOME/.zshrc.backup"
        
        # Set theme to agnoster (good for security work)
        sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="agnoster"/' "$USER_HOME/.zshrc"
        
        # Enable useful plugins for security work
        sed -i 's/plugins=(git)/plugins=(git docker python pip nmap ssh-agent sudo tmux colored-man-pages command-not-found extract z)/' "$USER_HOME/.zshrc"
        
        # Add custom aliases for security tools
        cat >> "$USER_HOME/.zshrc" << 'EOF'

# Add local bin to PATH if not already there
export PATH="$HOME/.local/bin:$PATH"

# Security tool aliases
alias nse='ls /usr/share/nmap/scripts/ | grep'
alias smbmap='smbclient -L'
alias hashcat64='hashcat'
alias serve='python3 -m http.server'
alias pyserve='python3 -m http.server'
alias phpserve='php -S 0.0.0.0:8000'

# Network aliases
alias ports='netstat -tulanp'
alias listening='netstat -tlnp'
alias myip='curl -s ifconfig.me'

# Security environment activation
alias activate-security='source /opt/security-tools-venv/bin/activate'
alias sec-env='source /opt/security-tools-venv/bin/activate'

# Proxychains aliases
alias pchains='proxychains4'
alias pc='proxychains4'

# Useful functions
extract_all() {
    for file in "$@"; do
        if [ -f "$file" ]; then
            case $file in
                *.tar.bz2)   tar xjf "$file"     ;;
                *.tar.gz)    tar xzf "$file"     ;;
                *.bz2)       bunzip2 "$file"     ;;
                *.rar)       unrar e "$file"     ;;
                *.gz)        gunzip "$file"      ;;
                *.tar)       tar xf "$file"      ;;
                *.tbz2)      tar xjf "$file"     ;;
                *.tgz)       tar xzf "$file"     ;;
                *.zip)       unzip "$file"       ;;
                *.Z)         uncompress "$file"  ;;
                *.7z)        7z x "$file"        ;;
                *)           echo "'$file' cannot be extracted" ;;
            esac
        else
            echo "'$file' is not a valid file"
        fi
    done
}

# Quick base64 encode/decode
b64e() { echo -n "$1" | base64; }
b64d() { echo -n "$1" | base64 -d; }

# Quick URL encode/decode
urlencode() { python3 -c "import urllib.parse; print(urllib.parse.quote('$1'))"; }
urldecode() { python3 -c "import urllib.parse; print(urllib.parse.unquote('$1'))"; }
EOF
        
        chown "$USER_NAME:$USER_NAME" "$USER_HOME/.zshrc"
    fi
}

# Install for root
install_oh_my_zsh "root" "/root"

# Install for sudo user
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    install_oh_my_zsh "$SUDO_USER" "$USER_HOME"
fi

# 11. Install kitty terminal
print_status "Installing kitty terminal..."
apt install -y kitty

# Configure kitty as default terminal for i3
print_status "Configuring kitty as default terminal for i3..."
# Create i3 config directory if it doesn't exist
I3_CONFIG_DIR="/etc/i3"
if [ -d "$I3_CONFIG_DIR" ]; then
    # Backup original config
    cp "$I3_CONFIG_DIR/config" "$I3_CONFIG_DIR/config.backup" 2>/dev/null || true
    
    # Update terminal binding in system-wide i3 config
    sed -i 's/bindsym \$mod+Return exec i3-sensible-terminal/bindsym \$mod+Return exec kitty/' "$I3_CONFIG_DIR/config" 2>/dev/null || true
    sed -i 's/bindsym \$mod+Return exec terminal/bindsym \$mod+Return exec kitty/' "$I3_CONFIG_DIR/config" 2>/dev/null || true
fi

# Also create user config template
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    USER_I3_DIR="$USER_HOME/.config/i3"
    mkdir -p "$USER_I3_DIR"
    chown "$SUDO_USER:$SUDO_USER" "$USER_I3_DIR"
    
    # Create a basic i3 config with kitty as default if it doesn't exist
    if [ ! -f "$USER_I3_DIR/config" ]; then
        cat > "$USER_I3_DIR/config" << 'EOF'
# i3 config file (v4)
# Set mod key (Mod1=Alt, Mod4=Windows key)
set $mod Mod4

# Font for window titles
font pango:monospace 8

# Start kitty terminal
bindsym $mod+Return exec kitty

# Kill focused window
bindsym $mod+Shift+q kill

# Start dmenu
bindsym $mod+d exec dmenu_run

# Launch polybar
exec_always --no-startup-id $HOME/.config/polybar/launch.sh

# Copy remaining config from system default
EOF
        # Append the rest of the default config, skipping the terminal binding and i3bar
        if [ -f "$I3_CONFIG_DIR/config" ]; then
            grep -v "bindsym \$mod+Return" "$I3_CONFIG_DIR/config" | \
            grep -v "^#.*config file" | \
            grep -v "^set \$mod" | \
            grep -v "^font pango" | \
            grep -v "bindsym \$mod+d exec dmenu" | \
            grep -v "bindsym \$mod+Shift+q kill" | \
            sed '/^bar {/,/^}/ d' >> "$USER_I3_DIR/config"
        fi
        chown "$SUDO_USER:$SUDO_USER" "$USER_I3_DIR/config"
    fi
fi

# Set kitty as the default x-terminal-emulator alternative
update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator /usr/bin/kitty 50
update-alternatives --set x-terminal-emulator /usr/bin/kitty

# Create basic kitty config for better defaults
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    KITTY_CONFIG_DIR="$USER_HOME/.config/kitty"
    mkdir -p "$KITTY_CONFIG_DIR"
    
    if [ ! -f "$KITTY_CONFIG_DIR/kitty.conf" ]; then
        cat > "$KITTY_CONFIG_DIR/kitty.conf" << 'EOF'
# Kitty Configuration
# Font configuration
font_family      monospace
font_size        11.0

# Shell integration
shell /usr/bin/zsh
shell_integration enabled

# Terminal bell
enable_audio_bell no

# Theme
background_opacity 0.95
background #1e1e1e

# Scrollback
scrollback_lines 10000

# URL handling
open_url_with default
detect_urls yes

# Performance
repaint_delay 10
input_delay 3
sync_to_monitor yes
EOF
        chown -R "$SUDO_USER:$SUDO_USER" "$KITTY_CONFIG_DIR"
    fi
fi

# 13. Install Obsidian
print_status "Installing Obsidian..."
# Check if snap is installed, if not install it
if ! command -v snap &> /dev/null; then
    print_warning "Snap not found, installing..."
    apt install -y snapd
    systemctl enable --now snapd.socket
    # Create symlink for classic snap support
    ln -s /var/lib/snapd/snap /snap 2>/dev/null || true
fi

# Install Obsidian via snap
snap install obsidian --classic

# Add Python scripts to PATH
print_status "Configuring PATH..."

# Create profile.d script to ensure Python scripts are in PATH
cat > /etc/profile.d/security-tools.sh << 'EOF'
# Security Tools PATH Configuration

# Ensure standard system directories are in PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Add snap bin directory to PATH
if [ -d "/snap/bin" ]; then
    export PATH="/snap/bin:$PATH"
fi

# Add user's local bin to PATH (where pipx installs tools)
if [ -d "$HOME/.local/bin" ]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# Add security tools virtual environment to PATH
if [ -d "/opt/security-tools-venv/bin" ]; then
    export PATH="/opt/security-tools-venv/bin:$PATH"
fi
EOF

chmod +x /etc/profile.d/security-tools.sh

# Also add to the user's zshrc for immediate availability
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [ -f "$USER_HOME/.zshrc" ]; then
        # Check if our PATH exports are already in zshrc, if not add them
        if ! grep -q "# Security Tools PATH" "$USER_HOME/.zshrc"; then
            cat >> "$USER_HOME/.zshrc" << 'EOF'

# Security Tools PATH (added by installation script)
# Ensure standard system directories are in PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
# Add snap bin directory to PATH
export PATH="/snap/bin:$PATH"
# Add user's local bin to PATH (where pipx installs tools)
export PATH="$HOME/.local/bin:$PATH"
# Add security tools virtual environment to PATH
export PATH="/opt/security-tools-venv/bin:$PATH"
EOF
            chown "$SUDO_USER:$SUDO_USER" "$USER_HOME/.zshrc"
            print_status "Added security tools PATH to $SUDO_USER's .zshrc"
        fi
    fi
fi

# Ensure pipx path is in PATH for the user
if [ -n "$SUDO_USER" ]; then
    su - "$SUDO_USER" -c "python3 -m pipx ensurepath" || print_warning "Failed to run pipx ensurepath for user"
else
    pipx ensurepath
fi

# Verify installations
print_status "Verifying installations..."
echo ""
echo "=== Installation Status ==="

# Function to check if command exists
check_tool() {
    if command -v $1 &> /dev/null; then
        echo -e "${GREEN}✓${NC} $1 installed successfully"
        
        # Skip version check for tools that don't support standard version flags
        case $1 in
            nslookup|dig|ping|netstat)
                echo "   (Version check skipped - tool available)"
                ;;
            *)
                $1 --version 2>/dev/null || $1 -v 2>/dev/null || echo "   Version info not available"
                ;;
        esac
    else
        echo -e "${RED}✗${NC} $1 installation failed or not in PATH"
    fi
}

check_tool nmap
check_tool ncat
check_tool ping
check_tool binwalk
check_tool smbclient
check_tool hashcat
check_tool java
check_tool i3
check_tool polybar
check_tool zsh
check_tool kitty
check_tool proxychains4
check_tool netstat

# Check Python tools
echo ""
echo "Python tools (system):"
python3 -m pip show dnsrecon &>/dev/null && echo -e "${GREEN}✓${NC} dnsrecon installed" || echo -e "${RED}✗${NC} dnsrecon not found"
dpkg -l | grep -q python3-certipy && echo -e "${GREEN}✓${NC} python3-certipy (apt) installed" || echo -e "${RED}✗${NC} python3-certipy (apt) not found"

echo ""
echo "Python tools (pipx - installed for user):"
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if su - "$SUDO_USER" -c "command -v netexec" &>/dev/null; then
        echo -e "${GREEN}✓${NC} netexec (pipx) installed for $SUDO_USER"
    else
        echo -e "${RED}✗${NC} netexec (pipx) not found for $SUDO_USER"
    fi
    if su - "$SUDO_USER" -c "command -v secretsdump.py" &>/dev/null; then
        echo -e "${GREEN}✓${NC} impacket (pipx) installed for $SUDO_USER"
    else
        echo -e "${RED}✗${NC} impacket (pipx) not found for $SUDO_USER"
    fi
else
    command -v netexec &>/dev/null && echo -e "${GREEN}✓${NC} netexec (pipx) installed" || echo -e "${RED}✗${NC} netexec (pipx) not found"
    command -v secretsdump.py &>/dev/null && echo -e "${GREEN}✓${NC} impacket (pipx) installed" || echo -e "${RED}✗${NC} impacket (pipx) not found"
fi

echo ""
echo "Security Tools Virtual Environment (/opt/security-tools-venv):"
if [ -d "$SECURITY_VENV" ]; then
    echo -e "${GREEN}✓${NC} Security tools virtual environment created"
    
    # Check tools in virtual environment
    source "$SECURITY_VENV/bin/activate"
    
    python -c "import impacket; print('✓ impacket installed in venv')" 2>/dev/null || echo -e "${RED}✗${NC} impacket not found in venv"
    python -c "import netifaces; print('✓ netifaces installed in venv')" 2>/dev/null || echo -e "${RED}✗${NC} netifaces not found in venv"
    python -c "import aioquic; print('✓ aioquic installed in venv')" 2>/dev/null || echo -e "${RED}✗${NC} aioquic not found in venv"
    python -c "import pyrebase; print('✓ pyrebase4 installed in venv')" 2>/dev/null || echo -e "${YELLOW}*${NC} pyrebase4 not installed in venv (optional)"
    command -v certipy &>/dev/null && echo -e "${GREEN}✓${NC} certipy-ad installed in venv" || echo -e "${RED}✗${NC} certipy-ad not found in venv"
    [ -d "$SECURITY_VENV/responder" ] && echo -e "${GREEN}✓${NC} Responder installed in venv" || echo -e "${RED}✗${NC} Responder not found in venv"
    
    deactivate
else
    echo -e "${RED}✗${NC} Security tools virtual environment not found"
fi

# Check wrapper scripts
echo ""
echo "Wrapper scripts:"
[ -f "/usr/local/bin/responder" ] && echo -e "${GREEN}✓${NC} responder wrapper created" || echo -e "${RED}✗${NC} responder wrapper not found"
[ -f "/usr/local/bin/certipy-venv" ] && echo -e "${GREEN}✓${NC} certipy-venv wrapper created" || echo -e "${RED}✗${NC} certipy-venv wrapper not found"

# Check Obsidian
if command -v obsidian &>/dev/null || [ -f /usr/local/bin/obsidian ]; then
    echo -e "${GREEN}✓${NC} Obsidian installed"
else
    echo -e "${RED}✗${NC} Obsidian not found"
fi

# Check DNS tools
echo ""
echo "DNS tools:"
check_tool nslookup
check_tool dig
check_tool dnsrecon
check_tool dnsenum

# Show Java versions
echo ""
echo "Java versions installed:"
update-alternatives --list java 2>/dev/null || echo "No Java alternatives configured"

# Show shell information
echo ""
echo "Shell configuration:"
echo "Current shell: $SHELL"
echo "Zsh location: $(which zsh)"
if [ -n "$SUDO_USER" ]; then
    echo "Default shell for $SUDO_USER: $(getent passwd "$SUDO_USER" | cut -d: -f7)"
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [ -d "$USER_HOME/.oh-my-zsh" ] && echo -e "${GREEN}✓${NC} Oh My Zsh installed for $SUDO_USER" || echo -e "${RED}✗${NC} Oh My Zsh not found for $SUDO_USER"
fi
[ -d "/root/.oh-my-zsh" ] && echo -e "${GREEN}✓${NC} Oh My Zsh installed for root" || echo -e "${RED}✗${NC} Oh My Zsh not found for root"

print_status "Installation complete!"
print_warning "IMPORTANT: Please start a NEW terminal session for PATH changes to take effect."
print_warning "The tools were installed for the user '$SUDO_USER', not root."
print_warning "If tools are not found, restart your terminal or run: source ~/.zshrc"

# Additional notes
echo ""
echo "=== Additional Notes ==="
echo "1. Security Tools Virtual Environment: /opt/security-tools-venv"
echo "   - Contains: impacket, responder, certipy-ad, netifaces, aioquic"
echo "   - Optional: pyrebase4 (may have failed to install, but script continues)"
echo "   - Owned by: $SUDO_USER (not root)"
echo "   - Activate with: source /opt/security-tools-venv/bin/activate"
echo "   - Or use alias: activate-security / sec-env"
echo "2. Tool Installation Methods:"
echo "   - netexec: Installed via pipx for user $SUDO_USER"
echo "   - impacket: Installed via pipx for user $SUDO_USER"
echo "   - python3-certipy: Installed via apt (system-wide)"
echo "   - certipy-ad: Installed in virtual environment (use certipy-venv wrapper)"
echo "   - responder: Installed from source in virtual environment"
echo "   - proxychains4: Installed via apt"
echo "   - net-tools: Installed via apt (provides netstat, ifconfig, etc.)"
echo "3. PATH Configuration:"
echo "   - Standard system directories: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
echo "   - Snap applications: /snap/bin"
echo "   - User pipx tools: /home/$SUDO_USER/.local/bin"
echo "   - Virtual environment: /opt/security-tools-venv/bin"
echo "   - Configuration file: /etc/profile.d/security-tools.sh"
echo "   - Also added to: /home/$SUDO_USER/.zshrc"
echo "   - python3-certipy: Installed via apt (system-wide)"
echo "   - certipy-ad: Installed in virtual environment (use certipy-venv wrapper)"
echo "   - impacket: Installed from source in virtual environment"
echo "   - responder: Installed from source in virtual environment"
echo "   - proxychains4: Installed via apt"
echo "   - net-tools: Installed via apt (provides netstat, ifconfig, etc.)"
echo "3. Wrapper Scripts (in /usr/local/bin):"
echo "   - responder: Runs Responder from the virtual environment"
echo "   - certipy-venv: Runs certipy-ad from the virtual environment"
echo "   - Various impacket scripts: Auto-generated wrappers for venv tools"
echo "4. Virtual Environment Tools Usage:"
echo "   - Direct: source /opt/security-tools-venv/bin/activate && certipy"
echo "   - Via wrapper: certipy-venv (already in PATH)"
echo "   - Responder: responder -I eth0 (wrapper script)"
echo "5. Proxychains Configuration:"
echo "   - Config file: /etc/proxychains4.conf"
echo "   - Usage: proxychains4 <command> or use aliases: pchains/pc"
echo "6. Network Tools:"
echo "   - netstat, ifconfig, route: Available via net-tools package"
echo "   - netifaces: Python library for network interface detection (in venv)"
echo "   - aioquic: QUIC protocol support (in venv)"
echo "7. Zsh Configuration Updates:"
echo "   - Added aliases for security environment activation"
echo "   - Added proxychains shortcuts (pchains, pc)"
echo "   - All previous aliases and functions remain available"
echo "8. Python Environment Structure:"
echo "   - System Python: Basic tools, dnsrecon, apt packages"
echo "   - pipx: Isolated tools like netexec"
echo "   - Security venv: Advanced tools requiring specific dependencies"
echo "9. For Obsidian, if using AppImage, you may need to install additional dependencies"
echo "10. Some tools may require additional configuration for full functionality"
echo "11. i3 window manager: Kitty is set as default terminal. Config locations:"
echo "    - System: /etc/i3/config"
echo "    - User: ~/.config/i3/config"
echo "12. Java: Installed default JRE and OpenJDK 8. To switch versions use: sudo update-alternatives --config java"
echo "13. Hashcat: For NVIDIA GPUs, install CUDA. For AMD GPUs, install ROCm for better performance"
echo "14. Polybar: Configured to replace i3bar with system monitoring modules"
echo "    - Config: ~/.config/polybar/config.ini"
echo "    - Launch script: ~/.config/polybar/launch.sh"
echo "    - Modules: workspaces, window title, CPU, memory, network, battery, date/time"
echo "15. pyrebase4: This package may fail to install due to dependency issues."
echo "    If you need Firebase functionality, consider installing it manually or using alternative packages."
echo "16. netexec: Requires Rust compiler. Script will attempt to install Rust automatically."
echo "    If installation still fails, manually install Rust and restart shell:"
echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
echo "    source ~/.cargo/env"
echo "    Then try: pipx install git+https://github.com/Pennyw0rth/NetExec"
echo ""
echo "=== Quick Start Commands ==="
echo "Activate security environment: activate-security"
echo "Run Responder: responder -I eth0"
echo "Run netexec: netexec smb <target>"
echo "Run certipy (venv): certipy-venv find -u user@domain"
echo "Run certipy (apt): certipy find -u user@domain"
echo "Use proxychains: pchains nmap <target>"
echo "Check network interfaces: python3 -c 'import netifaces; print(netifaces.interfaces())'"

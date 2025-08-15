#!/bin/bash
# Script to flash a local or downloaded Raspberry Pi OS Lite image to an SD card or flash drive,
# configure SSH with public key authentication and optional password, and set an optional static IP
# 
# Enhanced Features:
# - Smart device detection (SD card vs flash drive)
# - Intelligent formatting decisions based on device type
# - Enhanced safety warnings for large devices
# - Recovery guidance for failed operations
# - Support for both Ethernet and Wi-Fi static IP configuration
# Exit on any error
set -e

# Configuration owner (prefer invoking non-root user when run with sudo)
config_owner="${SUDO_USER:-$USER}"
config_owner_home=$(getent passwd "$config_owner" | cut -d: -f6 2>/dev/null)
config_owner_home=${config_owner_home:-$HOME}

# Configuration file path: store next to this script in the project folder
script_dir="$(cd "$(dirname "$0")" && pwd)"
config_dir="$script_dir"
config_file="$config_dir/flash_pios.json"

# Check write permissions and fallback to user config directory if needed
if [ ! -w "$config_dir" ]; then
    config_dir="$config_owner_home/.config/flash_pios"
    config_file="$config_dir/flash_pios.json"
    mkdir -p "$config_dir"
    echo "Warning: Script directory is not writable. Using $config_dir for configuration."
fi

# Logging setup with colors and headers
log_file="$config_dir/flash_pios.log"

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Log levels
LOG_INFO="INFO"
LOG_WARN="WARN"
LOG_ERROR="ERROR"

# Logger function with different levels and colors
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date -Iseconds)
    
    # Color coding based on log level
    local color=""
    local level_text=""
    
    case "$level" in
        "$LOG_INFO")
            color="$BLUE"
            level_text="[INFO]"
            ;;
        "$LOG_WARN")
            color="$YELLOW"
            level_text="[WARN]"
            ;;
        "$LOG_ERROR")
            color="$RED"
            level_text="[ERROR]"
            ;;
        *)
            color="$WHITE"
            level_text="[INFO]"
            ;;
    esac
    
    # Format: [LEVEL] timestamp - message
    local formatted_message="${color}${level_text}${NC} ${timestamp} - ${message}"
    
    # Display with color
    echo -e "$formatted_message"
    
    # Log to file without color codes
    echo "${level_text} ${timestamp} - ${message}" >> "$log_file"
}

# Initialize log file (overwrite each time)
init_log() {
    # Create config directory if it doesn't exist
    mkdir -p "$config_dir"
    
    # Clear and initialize log file
    > "$log_file"
    
    # Log script start
    log "$LOG_INFO" "Raspberry Pi OS Flashing Script Started"
    log "$LOG_INFO" "Log file: $log_file"
    log "$LOG_INFO" "Script version: 2.0 (Enhanced)"
    log "$LOG_INFO" "Timestamp: $(date)"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to validate IP address format
validate_ip() {
    local ip="$1"
    if ! echo "$ip" | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' >/dev/null; then
        return 1
    fi
    IFS='.' read -ra ADDR <<< "$ip"
    for i in "${ADDR[@]}"; do
        if [ "$i" -lt 0 ] || [ "$i" -gt 255 ]; then
            return 1
        fi
    done
    return 0
}

# Function to validate username format
validate_username() {
    local username="$1"
    if [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] && [ ${#username} -le 32 ]; then
        return 0
    else
        return 1
    fi
}

# Check for required tools
for cmd in wget dd xz lsblk sha256sum partprobe jq openssl pv numfmt bc; do
    if ! command_exists "$cmd"; then
        log "$LOG_ERROR" "$cmd is not installed. Please install it (e.g., 'sudo apt install $cmd')."
        exit 1
    fi
done

# Function to cleanup and exit on error
cleanup_and_exit() {
    local exit_code=$1
    local status=${2:-"failed"}
    
    log "$LOG_WARN" "Flash operation $status. Cleaning up..."
    
    # Always remove decompressed image file
    if [ -f "$image_file" ]; then
        rm -f "$image_file"
        log "$LOG_INFO" "Removed decompressed image: $image_file"
    fi
    
    # Clean up downloaded files if they exist
    if [ -z "$local_image" ]; then
        rm -f "raspios-lite-latest.img.xz" "raspios-lite-latest.sha256"
        if [ -n "$downloaded_xz" ]; then
            rm -f "$downloaded_xz"
        fi
    fi
    
    # Set flash status and save config
    last_flash_status="$status"
    write_config
    
    # Provide recovery guidance based on device type
    if [ -n "$device_type" ]; then
        echo ""
        echo "${CYAN}*** Recovery Guidance ***${NC}"
        if [ "$device_type" = "flash_drive" ]; then
            echo "  • This was a flash drive. To recover it for future use:"
            echo "    sudo dd if=/dev/zero of=$sd_card bs=1M count=1 conv=notrunc"
            echo "    sudo partprobe $sd_card"
            echo "  • Or use a disk utility like GParted to recreate partitions"
        elif [ "$device_type" = "sd_card" ]; then
            echo "  • This was an SD card. It may need to be reformatted:"
            echo "    sudo mkfs.vfat -F 32 ${sd_card}1"
        fi
        echo "  • Always backup important data before flashing!"
    fi
    
    exit "$exit_code"
}

# Initialize logging
init_log

# Set trap to cleanup on exit
trap 'cleanup_and_exit 1 "failed"' EXIT

# Load defaults from config (if present)
default_username=$(jq -r '.username // empty' "$config_file" 2>/dev/null || true)
default_arch=$(jq -r '.arch // empty' "$config_file" 2>/dev/null || true)
default_static_ip=$(jq -r '.static_ip // empty' "$config_file" 2>/dev/null || true)
default_gateway_ip=$(jq -r '.gateway_ip // empty' "$config_file" 2>/dev/null || true)
default_subnet_mask=$(jq -r '.subnet_mask // empty' "$config_file" 2>/dev/null || true)
default_dns_server=$(jq -r '.dns_server // empty' "$config_file" 2>/dev/null || true)
default_local_image=$(jq -r '.local_image // empty' "$config_file" 2>/dev/null || true)
default_password=$(jq -r '.password // empty' "$config_file" 2>/dev/null || true)
default_confirm_erase=$(jq -r '.confirm_erase // empty' "$config_file" 2>/dev/null || true)
default_confirm_format=$(jq -r '.confirm_format // empty' "$config_file" 2>/dev/null || true)
default_confirm_flash=$(jq -r '.confirm_flash // empty' "$config_file" 2>/dev/null || true)
downloaded_xz=""

# Helper to persist configuration to JSON
write_config() {
    persist_json=$(jq -n \
        --arg username "$username" \
        --arg arch "$arch" \
        --arg static_ip "${static_ip}" \
        --arg gateway_ip "${gateway_ip}" \
        --arg subnet_mask "${subnet_mask:-24}" \
        --arg dns_server "${dns_server:-8.8.8.8}" \
        --arg local_image "${local_image}" \
        --arg password "${password}" \
        --arg confirm_erase "${confirm:-N}" \
        --arg confirm_format "${format_confirm:-N}" \
        --arg confirm_flash "${flash_confirm:-N}" \
        --arg last_flash_status "${last_flash_status:-unknown}" \
        --arg last_flash_date "$(date -Iseconds)" \
        '{username:$username, arch:$arch, static_ip:$static_ip, gateway_ip:$gateway_ip, subnet_mask:$subnet_mask, dns_server:$dns_server, local_image:$local_image, password:$password, confirm_erase:$confirm_erase, confirm_format:$confirm_format, confirm_flash:$confirm_flash, last_flash_status:$last_flash_status, last_flash_date:$last_flash_date}')
    echo "$persist_json" > "$config_file"
    if [ -n "$config_owner" ] && [ "$config_owner" != "root" ]; then
        chown "$config_owner":"$config_owner" "$config_file" 2>/dev/null || true
    fi
}

# Function to display a terminal selector with arrow key navigation
select_device() {
    local devices=("$@")
    local selected=0
    local max_index=$((${#devices[@]} - 1))
    
    # Terminal settings
    tput init
    tput clear
    
    while true; do
        # Display devices
        tput clear
        echo "Available block devices (excluding boot device $boot_device):"
        echo "Format: Device Size Model MountPoints Type"
        echo ""
        for i in "${!devices[@]}"; do
            local device_info="${devices[$i]}"
            local device_name=$(echo "$device_info" | awk '{print $1}')
            local device_size=$(echo "$device_info" | awk '{print $2}')
            local device_model=$(echo "$device_info" | awk '{print $3}')
            local device_mounts=$(echo "$device_info" | awk '{print $4}')
            local device_type=$(echo "$device_info" | awk '{print $5}')
            
            # Determine device category for better display
            local device_category=""
            if [ "$device_type" = "disk" ]; then
                if [ "$device_size" =~ "G" ] && [ "${device_size%G}" -gt 16 ]; then
                    device_category="[FLASH DRIVE]"
                else
                    device_category="[STORAGE]"
                fi
            elif [ "$device_type" = "part" ]; then
                device_category="[PARTITION]"
            else
                device_category="[$device_type]"
            fi
            
            if [ "$i" -eq "$selected" ]; then
                echo -e "\033[1;32m> $device_name $device_size $device_model $device_mounts $device_category\033[0m"
            else
                echo "  $device_name $device_size $device_model $device_mounts $device_category"
            fi
        done
        echo ""
        echo "Use arrow keys to navigate, Enter to select, or Ctrl+C to abort."
        
        # Read a single keypress
        read -rsn1 key
        if [ "$key" = $'\x1b' ]; then
            read -rsn2 key
            case "$key" in
                '[A') # Up arrow
                    ((selected--))
                    if [ "$selected" -lt 0 ]; then
                        selected="$max_index"
                    fi
                    ;;
                '[B') # Down arrow
                    ((selected++))
                    if [ "$selected" -gt "$max_index" ]; then
                        selected=0
                    fi
                    ;;
            esac
        elif [ -z "$key" ]; then # Enter key
            sd_card="/dev/${devices[$selected]%% *}"
            tput clear
            break
        fi
    done
}

# Function to detect boot and rootfs partitions dynamically
detect_partitions() {
    local sd_card="$1"
    local boot_part=""
    local root_part=""
    
    log "$LOG_INFO" "Detecting partitions on $sd_card..."
    
    # Wait for partitions to be recognized
    sudo partprobe "$sd_card" 2>/dev/null || true
    sleep 2
    
    # Get partition information
    mapfile -t partitions < <(lsblk -J -o NAME,FSTYPE "$sd_card" 2>/dev/null | jq -r '.blockdevices[].children[]? | "\(.name) \(.fstype)"' 2>/dev/null || echo "")
    
    for part in "${partitions[@]}"; do
        if [ -z "$part" ]; then continue; fi
        name=$(echo "$part" | awk '{print $1}')
        fstype=$(echo "$part" | awk '{print $2}')
        
        if [ "$fstype" = "vfat" ] && [ -z "$boot_part" ]; then
            boot_part="/dev/$name"
            log "$LOG_INFO" "Found boot partition: $boot_part (FAT32)"
        elif [ "$fstype" = "ext4" ] && [ -z "$root_part" ]; then
            root_part="/dev/$name"
            log "$LOG_INFO" "Found rootfs partition: $root_part (ext4)"
        fi
    done
    
    if [ -z "$boot_part" ] || [ -z "$root_part" ]; then
        log "$LOG_ERROR" "Could not detect boot (vfat) or rootfs (ext4) partitions on $sd_card."
        log "$LOG_INFO" "Available partitions:"
        lsblk "$sd_card" 2>/dev/null || true
        return 1
    fi
    
    echo "$boot_part:$root_part"
}

# Function to configure user
configure_user() {
    local username="$1"
    local password="$2"
    local pubkey="$3"
    local root_mnt="$4"
    
    log "$LOG_INFO" "Configuring user $username..."
    
    # Check if username already exists in /etc/passwd
    if grep -q "^$username:" "$root_mnt/etc/passwd"; then
        log "$LOG_INFO" "User $username already exists in the image. Updating existing user configuration..."
        # Remove existing user entries
        sudo sed -i "/^$username:/d" "$root_mnt/etc/passwd"
        sudo sed -i "/^$username:/d" "$root_mnt/etc/group"
        sudo sed -i "/^$username:/d" "$root_mnt/etc/shadow"
        log "$LOG_INFO" "Removed existing user $username entries."
    fi
    
    # Create user configuration
    echo "$username:x:1000:1000:Raspberry Pi User:/home/$username:/bin/bash" | sudo tee -a "$root_mnt/etc/passwd" >/dev/null
    echo "$username:x:1000:" | sudo tee -a "$root_mnt/etc/group" >/dev/null
    
    # Add to standard groups
    for group in adm dialout cdrom sudo audio video plugdev games users input netdev spi i2c gpio; do
        if grep -q "^$group:" "$root_mnt/etc/group"; then
            sudo sed -i "/^$group:/ s/$/,$username/" "$root_mnt/etc/group"
        fi
    done
    
    # Set up shadow entry
    lastchange=$(($(date +%s)/86400))
    if [ -n "$password" ]; then
        hash=$(echo -n "$password" | openssl passwd -6 -stdin)
    else
        hash="!"
    fi
    echo "$username:$hash:$lastchange:0:99999:7:::" | sudo tee -a "$root_mnt/etc/shadow" >/dev/null
    
    # Set up sudoers
    echo "$username ALL=(ALL) NOPASSWD: ALL" | sudo tee "$root_mnt/etc/sudoers.d/010_$username-nopasswd" >/dev/null
    sudo chmod 0440 "$root_mnt/etc/sudoers.d/010_$username-nopasswd"
    
    # Set up SSH key
    sudo mkdir -p "$root_mnt/home/$username/.ssh"
    echo "$pubkey" | sudo tee "$root_mnt/home/$username/.ssh/authorized_keys" >/dev/null
    sudo chmod 700 "$root_mnt/home/$username/.ssh"
    sudo chmod 600 "$root_mnt/home/$username/.ssh/authorized_keys"
    sudo chown -R 1000:1000 "$root_mnt/home/$username"
    
    log "$LOG_INFO" "User $username configured successfully"
}

# Function to configure SSH
configure_ssh() {
    local username="$1"
    local password="$2"
    local root_mnt="$3"
    
    log "$LOG_INFO" "Configuring SSH server..."
    
    # Enable SSH
    sudo touch "$root_mnt/boot/ssh"
    
    # Configure SSH server for security
    sudo sed -i 's/#PermitRootLogin .*/PermitRootLogin no/' "$root_mnt/etc/ssh/sshd_config"
    echo "AllowUsers $username" | sudo tee -a "$root_mnt/etc/ssh/sshd_config" >/dev/null
    if [ -z "$password" ]; then
        sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' "$root_mnt/etc/ssh/sshd_config"
    fi
    
    log "$LOG_INFO" "SSH configured successfully"
}

# Function to configure static IP
configure_static_ip() {
    local static_ip="$1"
    local gateway_ip="$2"
    local subnet_mask="$3"
    local dns_server="$4"
    local root_mnt="$5"
    
    log "$LOG_INFO" "Configuring static IP $static_ip..."
    
    # Prompt for interface (Ethernet or Wi-Fi)
    echo "Choose network interface for static IP:"
    echo "[0] eth0 (Ethernet)"
    echo "[1] wlan0 (Wi-Fi)"
    read -r interface_choice
    case "$interface_choice" in
        1) interface="wlan0" ;;
        *) interface="eth0" ;;
    esac
    
    # For Wi-Fi, prompt for SSID and password
    if [ "$interface" = "wlan0" ]; then
        echo "Enter Wi-Fi SSID:"
        read -r wifi_ssid
        echo "Enter Wi-Fi password (leave empty for open network):"
        read -r -s wifi_password
        echo
        
        # Configure Wi-Fi
        sudo tee "$root_mnt/boot/wpa_supplicant.conf" >/dev/null <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
    ssid="$wifi_ssid"
    $(if [ -n "$wifi_password" ]; then echo "psk=\"$wifi_password\""; else echo "key_mgmt=NONE"; fi)
}
EOF
        log "$LOG_INFO" "Wi-Fi configuration added for $wifi_ssid"
    fi
    
    # Check if dhcpcd.conf exists, create if it doesn't
    if [ ! -f "$root_mnt/etc/dhcpcd.conf" ]; then
        log "$LOG_INFO" "Creating dhcpcd.conf file..."
        sudo touch "$root_mnt/etc/dhcpcd.conf"
    fi
    
    # Remove any existing configuration for the selected interface
    if grep -q "interface $interface" "$root_mnt/etc/dhcpcd.conf"; then
        log "$LOG_INFO" "Removing existing $interface configuration from dhcpcd.conf..."
        sudo sed -i "/interface $interface/,/^\s*$/d" "$root_mnt/etc/dhcpcd.conf"
    fi
    
    # Append static IP configuration
    echo -e "\ninterface $interface\nstatic ip_address=$static_ip/$subnet_mask\nstatic routers=$gateway_ip\nstatic domain_name_servers=$dns_server\nnohook lookup-hostname" | sudo tee -a "$root_mnt/etc/dhcpcd.conf" >/dev/null
    log "$LOG_INFO" "Static IP configuration added for $interface in dhcpcd.conf"
    
    # Ensure DHCP is disabled for this interface
    echo "denyinterfaces $interface" | sudo tee -a "$root_mnt/etc/dhcpcd.conf" >/dev/null
    log "$LOG_INFO" "DHCP disabled for $interface"
}

# Function to download and verify image
download_image() {
    local arch="$1"
    local local_image="$2"
    
    if [ -n "$local_image" ]; then
        # Validate local image
        if [ ! -f "$local_image" ]; then
            log "Error: Local image file $local_image does not exist."
            return 1
        fi
        if [[ "$local_image" != *.img && "$local_image" != *.img.xz ]]; then
            log "Error: Local image must have a .img or .img.xz extension."
            return 1
        fi
        log "Using local image: $local_image"
        
        if [[ "$local_image" == *.img.xz ]]; then
            log "Decompressing local image $local_image..."
            image_file="${local_image%.xz}"
            
            # Get compressed file size for progress display
            compressed_size=$(stat -c %s "$local_image" 2>/dev/null || stat -f %z "$local_image" 2>/dev/null || echo "0")
            
            if [ "$compressed_size" -gt 0 ]; then
                log "Compressed size: $(numfmt --to=iec-i --suffix=B $compressed_size)"
                log "Decompressing with progress..."
                
                if command_exists pv; then
                    # Use pv to show decompression progress
                    echo "Progress: ["
                    
                    # Use pv with explicit progress display and force unbuffered output
                    if ! stdbuf -oL pv -s "$compressed_size" -p -t -e -r -f -B 65536 "$local_image" 2>/dev/tty | xz -dc > "$image_file"; then
                        log "Error: Failed to decompress $local_image."
                        return 1
                    fi
                    echo "] Decompression completed successfully!"
                else
                    # Fallback to xz with verbose output
                    if ! xz -dkv "$local_image"; then
                        log "Error: Failed to decompress $local_image."
                        return 1
                    fi
                fi
            else
                # Fallback if size detection fails
                if ! xz -dk "$local_image"; then
                    log "Error: Failed to decompress $local_image."
                    return 1
                fi
            fi
            
            log "Decompression completed: $image_file"
        else
            image_file="$local_image"
        fi
    else
        # Set the static URL for the latest Raspberry Pi OS Lite
        if [ "$arch" = "64" ]; then
            download_url="https://downloads.raspberrypi.org/raspios_lite_arm64_latest"
        else
            download_url="https://downloads.raspberrypi.org/raspios_lite_armhf_latest"
        fi
        checksum_url="$download_url.sha256"
        
        # Download the latest image and checksum
        log "Downloading the latest Raspberry Pi OS Lite ($arch-bit)..."
        wget -O raspios-lite-latest.img.xz "$download_url" --show-progress
        wget -O raspios-lite-latest.sha256 "$checksum_url" --show-progress
        
        # Verify the download
        if [ ! -f "raspios-lite-latest.img.xz" ] || [ ! -f "raspios-lite-latest.sha256" ]; then
            log "Error: Download failed."
            return 1
        fi
        
        # Rename the downloaded file to match the name in the checksum file (if provided)
        expected_xz=$(awk '{print $2}' raspios-lite-latest.sha256 | tr -d '\r')
        downloaded_xz="raspios-lite-latest.img.xz"
        if [ -n "$expected_xz" ]; then
            mv -f "$downloaded_xz" "$expected_xz"
            downloaded_xz="$expected_xz"
        fi
        
        log "Verifying image integrity..."
        if ! sha256sum -c raspios-lite-latest.sha256; then
            log "Error: Image verification failed."
            return 1
        fi
        
        # Decompress the image
        log "Decompressing $downloaded_xz..."
        xz -dk "$downloaded_xz"
        image_file="${downloaded_xz%.xz}"
    fi
    
    return 0
}

# Function to write image to SD card
write_image() {
    local image_file="$1"
    local sd_card="$2"
    
    log "Writing $image_file to $sd_card..."
    log "This may take several minutes. Please wait..."
    
    # Check if image file exists and has size
    if [ ! -f "$image_file" ]; then
        log "Error: Image file $image_file not found!"
        return 1
    fi
    
    image_size=$(stat -c %s "$image_file" 2>/dev/null || stat -f %z "$image_file" 2>/dev/null || echo "0")
    if [ "$image_size" -eq 0 ]; then
        log "Error: Image file $image_file has zero size!"
        return 1
    fi
    
    log "Image size: $(numfmt --to=iec-i --suffix=B $image_size)"
    log "Starting write operation..."
    
    # Use pv with better progress display
    if command_exists pv; then
        echo "Progress: ["
        
        # Force progress output and reduce buffering
        if ! stdbuf -oL pv -s "$image_size" -p -t -e -r -f -B 65536 "$image_file" 2>/dev/tty | sudo dd bs=4M of="$sd_card" conv=fsync; then
            log "Error: Failed to write image to SD card!"
            return 1
        fi
        echo "] Write completed successfully!"
    else
        log "pv not available, using dd with progress..."
        sudo dd bs=4M if="$image_file" of="$sd_card" conv=fsync status=progress
    fi
    
    # Check if write was successful
    if [ $? -ne 0 ]; then
        log "Error: Failed to write image to SD card!"
        return 1
    fi
    
    # Sync to ensure all data is written
    sync
    log "Image written successfully to $sd_card"
    return 0
}

# Get the boot device (parent device, not partition)
boot_device=$(lsblk -o NAME,MOUNTPOINTS | grep -E '[[:space:]]/(boot/firmware|/)' | head -n 1 | awk '{print $1}' | sed 's/[├─│└].*//')
boot_device="/dev/$boot_device"
if [ ! -b "$boot_device" ]; then
            log "$LOG_WARN" "Could not detect boot device. Assuming none."
    boot_device=""
else
    log "$LOG_INFO" "Boot device detected: $boot_device"
fi

# Automatically detect block devices (prefer removable, exclude boot device)
log "$LOG_INFO" "Detecting block devices..."
mapfile -t devices < <(lsblk -J -o NAME,SIZE,RM,MODEL,MOUNTPOINTS,TYPE | jq -r --arg bootdev "$boot_device" '.blockdevices[] | select(.name != $bootdev and .name != "") | select(.rm == true or .rm == "1") | "\(.name) \(.size) \(.model // "Unknown") \(.mountpoints | join(",")) \(.type)"' 2>/dev/null)
if [ ${#devices[@]} -eq 0 ]; then
    log "$LOG_WARN" "No removable block devices found. Listing all available block devices (excluding $boot_device):"
    mapfile -t devices < <(lsblk -J -o NAME,SIZE,MODEL,MOUNTPOINTS,TYPE | jq -r --arg bootdev "$boot_device" '.blockdevices[] | select(.name != $bootdev and .name != "") | "\(.name) \(.size) \(.model // "Unknown") \(.mountpoints | join(",")) \(.type)"' 2>/dev/null)
    if [ ${#devices[@]} -eq 0 ]; then
        log "$LOG_ERROR" "No block devices found. Please insert an SD card or flash drive."
        exit 1
    fi
fi

# Use terminal selector if multiple devices are found
if [ ${#devices[@]} -eq 1 ]; then
    sd_card="/dev/${devices[0]%% *}"
    log "$LOG_INFO" "Found one block device: $sd_card (${devices[0]})"
else
    select_device "${devices[@]}"
fi

# Show device size
size=$(lsblk -b -o SIZE "$sd_card" | tail -n 1)
size_gb=$(echo "scale=1; $size / 1024 / 1024 / 1024" | bc -l 2>/dev/null || echo "unknown")
log "$LOG_INFO" "Selected device: $sd_card (${size_gb} GB)"

# Enhanced confirmation with device-specific warnings
echo ""
if [ "$device_type" = "flash_drive" ]; then
    echo "${RED}*** FLASH DRIVE DETECTED ***${NC}"
    echo "Device: $sd_card (${device_size_gb} GB)"
    echo "This appears to be a USB flash drive or large storage device."
    echo ""
    echo "${YELLOW}WARNING: All data on this device will be completely erased!${NC}"
    echo "This operation cannot be undone."
    echo ""
    echo "Are you absolutely sure you want to continue? (y/N):"
elif [ "$device_type" = "sd_card" ]; then
    echo "${BLUE}*** SD CARD DETECTED ***${NC}"
    echo "Device: $sd_card (${device_size_gb} GB)"
    echo ""
    echo "${YELLOW}WARNING: All data on this SD card will be erased. Continue? (y/N):${NC}"
else
    echo "${MAGENTA}*** STORAGE DEVICE DETECTED ***${NC}"
    echo "Device: $sd_card (${device_size_gb} GB)"
    echo ""
    echo "${YELLOW}WARNING: All data on this device will be erased. Continue? (y/N):${NC}"
fi

read -r confirm
confirm=${confirm:-"N"}
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    log "Aborted."
    exit 1
fi

# Additional confirmation for large devices
if [ "$device_size_gb" -gt 16 ]; then
    echo ""
    echo "${RED}*** FINAL WARNING ***${NC}"
    echo "This is a large device (${device_size_gb} GB). Are you sure you want to erase it?"
    echo "Type 'YES' to confirm:"
    read -r final_confirm
    if [ "$final_confirm" != "YES" ]; then
        log "$LOG_WARN" "Aborted by user."
        exit 1
    fi
fi

# Smart formatting decision based on device type and size
log "$LOG_INFO" "Analyzing device characteristics..."
device_size_gb=$(echo "scale=1; $size / 1024 / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
device_type="unknown"

# Detect if it's likely a flash drive vs SD card
if [ "$device_size_gb" -gt 16 ]; then
    device_type="flash_drive"
    log "$LOG_INFO" "Device appears to be a flash drive (${device_size_gb} GB)"
elif [ "$device_size_gb" -gt 1 ]; then
    device_type="sd_card"
    log "$LOG_INFO" "Device appears to be an SD card (${device_size_gb} GB)"
else
    device_type="small_device"
    log "$LOG_INFO" "Device appears to be a small storage device (${device_size_gb} GB)"
fi

# Check if device is removable
is_removable=$(lsblk -d -o RM "$sd_card" | tail -n 1)
if [ "$is_removable" = "1" ]; then
    log "$LOG_INFO" "Device is removable (likely USB flash drive or external SD card reader)"
else
    log "$LOG_WARN" "Device is not removable (likely internal storage - BE CAREFUL!)"
fi

# Smart formatting decision
format_recommended="N"
format_reason=""
if [ "$device_type" = "flash_drive" ] && [ "$is_removable" = "1" ]; then
    format_recommended="N"
    format_reason="Flash drives work better without pre-formatting for Raspberry Pi OS images"
elif [ "$device_type" = "sd_card" ] || [ "$device_type" = "small_device" ]; then
    format_recommended="Y"
    format_reason="SD cards benefit from fresh formatting before flashing"
else
    format_recommended="N"
    format_reason="Unknown device type - safer to skip formatting"
fi

# Show formatting recommendation
echo ""
echo "Device Analysis:"
echo "  Type: $device_type"
echo "  Size: ${device_size_gb} GB"
echo "  Removable: $([ "$is_removable" = "1" ] && echo "Yes" || echo "No")"
echo "  Recommendation: $([ "$format_recommended" = "Y" ] && echo "Format" || echo "Skip formatting")"
echo "  Reason: $format_reason"
echo ""

# Ask user about formatting with smart defaults
echo "Do you want to format $sd_card before flashing? (y/N) (default: ${format_recommended}):"
read -r format_confirm
format_confirm=${format_confirm:-$format_recommended}

if [ "$format_confirm" = "y" ] || [ "$format_confirm" = "Y" ]; then
    log "$LOG_INFO" "Formatting $sd_card..."
    
    # Unmount any existing partitions
    sudo umount "${sd_card}"* 2>/dev/null || true
    
    if [ "$device_type" = "flash_drive" ]; then
        # For flash drives, just clear the partition table without creating new partitions
        log "$LOG_INFO" "Clearing partition table for flash drive (no new partitions will be created)..."
        sudo dd if=/dev/zero of="$sd_card" bs=1M count=1 conv=notrunc
        log "$LOG_INFO" "Partition table cleared. The image will create its own partition structure."
    else
        # For SD cards, create a new partition table and format
        log "$LOG_INFO" "Creating new partition table and formatting for SD card..."
        sudo dd if=/dev/zero of="$sd_card" bs=1M count=1 conv=notrunc
        
        # Create new partition table
        log "$LOG_INFO" "Creating new partition table..."
        echo -e "o\nn\np\n1\n\n\nw" | sudo fdisk "$sd_card"
        
        # Wait for partition to be recognized
        sudo partprobe "$sd_card"
        sleep 2
        
        # Format the first partition as FAT32
        if [ -b "${sd_card}1" ]; then
            log "$LOG_INFO" "Formatting ${sd_card}1 as FAT32..."
            sudo mkfs.vfat -F 32 "${sd_card}1" 2>&1 | tee /tmp/mkfs_output.log
            
            if [ ${PIPESTATUS[0]} -eq 0 ]; then
                log "$LOG_INFO" "FAT32 formatting completed successfully."
            else
                log "$LOG_WARN" "FAT32 formatting had issues. Check /tmp/mkfs_output.log for details."
                log "$LOG_WARN" "Continuing with existing format..."
            fi
        else
            log "$LOG_WARN" "Partition ${sd_card}1 not found. Continuing with existing format..."
        fi
    fi
    
    # Refresh partition table
    sudo partprobe "$sd_card"
    sleep 2
fi

# Final confirmation before flashing
echo "Ready to flash Raspberry Pi OS to $sd_card. Continue? (y/N) (default: ${default_confirm_flash:-N}):"
read -r flash_confirm
flash_confirm=${flash_confirm:-${default_confirm_flash:-N}}
if [ "$flash_confirm" != "y" ] && [ "$flash_confirm" != "Y" ]; then
    log "$LOG_WARN" "Aborted."
    exit 1
fi

# Prompt for username and architecture
log "$LOG_INFO" "Prompting for user configuration..."
echo "Enter username for the Raspberry Pi (default: ${default_username:-pi}):"
read -r username
username=${username:-${default_username:-pi}}
log "$LOG_INFO" "Username set to: $username"

# Validate username
if ! validate_username "$username"; then
    log "$LOG_ERROR" "Invalid username format. Username must start with a letter or underscore, contain only lowercase letters, numbers, hyphens, and underscores, and be 32 characters or less."
    exit 1
fi

echo "Enter password for user $username (leave empty for key-only authentication) (default: ${default_password:-}):"
read -r -s password
password=${password:-$default_password}
if [ -n "$password" ]; then
    log "$LOG_INFO" "Password set for user $username"
else
    log "$LOG_INFO" "No password set - key-only authentication will be used"
fi
echo
echo "Choose architecture: 32 or 64 (default: ${default_arch:-64}):"
read -r arch
arch=${arch:-${default_arch:-64}}
log "$LOG_INFO" "Architecture set to: $arch-bit"
write_config
log "$LOG_INFO" "User configuration saved"

# Prompt for static IP address
log "$LOG_INFO" "Prompting for network configuration..."
echo "Enter the static IP address for the Raspberry Pi (e.g., 192.168.0.100) or press Enter to skip (default: ${default_static_ip:-none}):"
read -r static_ip
static_ip=${static_ip:-$default_static_ip}

if [ -n "$static_ip" ]; then
    log "$LOG_INFO" "Static IP requested: $static_ip"
    # Validate static IP
    if ! validate_ip "$static_ip"; then
        log "$LOG_ERROR" "Invalid IP address format: $static_ip"
        exit 1
    fi
    
    echo "Enter your network's gateway/router IP (e.g., 192.168.0.1) (default: ${default_gateway_ip:-}):"
    read -r gateway_ip
    gateway_ip=${gateway_ip:-$default_gateway_ip}
    
    if [ -z "$gateway_ip" ]; then
        log "$LOG_ERROR" "Gateway IP cannot be empty if static IP is set."
        exit 1
    fi
    
    # Validate gateway IP
    if ! validate_ip "$gateway_ip"; then
        log "$LOG_ERROR" "Invalid gateway IP address format: $gateway_ip"
        exit 1
    fi
    
    subnet_mask="${default_subnet_mask:-24}"
    dns_server="${default_dns_server:-8.8.8.8}"
    log "$LOG_INFO" "Network configuration: IP=$static_ip, Gateway=$gateway_ip, Subnet=/$subnet_mask, DNS=$dns_server"
else
    log "$LOG_INFO" "No static IP requested - will use DHCP"
fi
write_config
log "$LOG_INFO" "Network configuration saved"

# Determine which user's SSH key to use (prefer the invoking non-root user if run with sudo)
ssh_user="${SUDO_USER:-$USER}"
ssh_user_home=$(getent passwd "$ssh_user" | cut -d: -f6 2>/dev/null)
ssh_user_home=${ssh_user_home:-$HOME}

# Check for or generate SSH key pair
log "$LOG_INFO" "Setting up SSH authentication..."
if [ ! -f "$ssh_user_home/.ssh/id_ed25519" ]; then
    log "$LOG_INFO" "No SSH key found for $ssh_user. Generating a new ED25519 key pair..."
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" -H mkdir -p "$ssh_user_home/.ssh"
        sudo -u "$SUDO_USER" -H ssh-keygen -t ed25519 -C "$username@raspberrypi" -N "" -f "$ssh_user_home/.ssh/id_ed25519"
    else
        mkdir -p "$ssh_user_home/.ssh"
        ssh-keygen -t ed25519 -C "$username@raspberrypi" -N "" -f "$ssh_user_home/.ssh/id_ed25519"
    fi
    log "$LOG_INFO" "SSH key pair generated successfully"
else
    log "$LOG_INFO" "Using existing SSH key for $ssh_user"
fi
pubkey=$(cat "$ssh_user_home/.ssh/id_ed25519.pub")
if [ -z "$pubkey" ]; then
    log "$LOG_ERROR" "Failed to read public key."
    exit 1
fi
log "$LOG_INFO" "SSH public key loaded successfully"

# Prompt for local image file
log "$LOG_INFO" "Prompting for image selection..."
echo "Enter the path to a local Raspberry Pi OS Lite image (.img or .img.xz) or press Enter to download the latest${default_local_image:+ [default: $default_local_image]}:"
read -r local_image
local_image=${local_image:-$default_local_image}
image_file="raspios-lite-latest.img"

if [ -n "$local_image" ]; then
    log "$LOG_INFO" "Local image selected: $local_image"
else
    log "$LOG_INFO" "Will download latest Raspberry Pi OS Lite image"
fi

write_config
log "$LOG_INFO" "Image configuration saved"

# Download and verify image
if ! download_image "$arch" "$local_image"; then
    cleanup_and_exit 1 "failed"
fi

# Unmount all partitions of the SD card
log "$LOG_INFO" "Unmounting SD card partitions..."
sudo umount "${sd_card}"* 2>/dev/null || true

# Write the image to the SD card
if ! write_image "$image_file" "$sd_card"; then
    cleanup_and_exit 1 "failed"
fi

# Refresh partition table
log "$LOG_INFO" "Refreshing partition table..."
if ! sudo partprobe "$sd_card"; then
    log "$LOG_WARN" "Failed to refresh partition table. Waiting 2 seconds..."
    sleep 2
fi
sudo udevadm settle || sleep 2

# Detect partitions dynamically
partition_info=$(detect_partitions "$sd_card")
if [ $? -ne 0 ]; then
    cleanup_and_exit 1 "failed"
fi

boot_part=$(echo "$partition_info" | cut -d: -f1)
root_part=$(echo "$partition_info" | cut -d: -f2)

# Mount the boot and rootfs partitions
log "$LOG_INFO" "Mounting SD card partitions..."
boot_mnt=$(mktemp -d)
root_mnt=$(mktemp -d)
log "$LOG_INFO" "Created mount points: boot=$boot_mnt, root=$root_mnt"

if ! sudo mount "$boot_part" "$boot_mnt"; then
    log "$LOG_ERROR" "Failed to mount $boot_part"
    cleanup_and_exit 1 "failed"
fi
log "$LOG_INFO" "Boot partition mounted successfully"

if ! sudo mount "$root_part" "$root_mnt"; then
    log "$LOG_ERROR" "Failed to mount $root_part"
    cleanup_and_exit 1 "failed"
fi
log "$LOG_INFO" "Root partition mounted successfully"

# Configure user
configure_user "$username" "$password" "$pubkey" "$root_mnt"

# Configure SSH
configure_ssh "$username" "$password" "$root_mnt"

# Configure static IP (if provided)
if [ -n "$static_ip" ]; then
    configure_static_ip "$static_ip" "$gateway_ip" "$subnet_mask" "$dns_server" "$root_mnt"
fi

# Unmount partitions
log "$LOG_INFO" "Unmounting partitions..."
sudo umount "$boot_mnt" "$root_mnt" || true
rmdir "$boot_mnt" "$root_mnt"
log "$LOG_INFO" "Partitions unmounted and mount points cleaned up"

# Eject the SD card
log "$LOG_INFO" "Ejecting SD card..."
sudo eject "$sd_card" || true
log "$LOG_INFO" "SD card ejected"

# Clean up
log "$LOG_INFO" "Cleaning up temporary files..."

# Always remove decompressed image file, whether local or downloaded
if [ -f "$image_file" ]; then
    rm -f "$image_file"
    log "$LOG_INFO" "Removed decompressed image: $image_file"
fi

# Clean up downloaded files if they exist
if [ -z "$local_image" ]; then
    # Clean up downloaded artifacts regardless of renamed filename
    rm -f "raspios-lite-latest.img.xz" "raspios-lite-latest.sha256"
    if [ -n "$downloaded_xz" ]; then
        rm -f "$downloaded_xz"
    fi
    log "$LOG_INFO" "Downloaded files cleaned up"
fi

# Clean up any other temporary files that might exist
rm -f "raspios-lite-latest.img" "*.log" "*.tmp" 2>/dev/null || true

log "$LOG_INFO" "Cleanup completed. Only original image files remain."

# Remove trap since we're exiting normally
trap - EXIT

log "$LOG_INFO" "SD card has been formatted, flashed, and configured successfully!"
log "$LOG_INFO" "You can now remove the SD card and insert it into your Raspberry Pi."
if [ -n "$static_ip" ]; then
    log "$LOG_INFO" "Try SSH with: ssh $username@$static_ip"
else
    log "$LOG_INFO" "Try SSH with: ssh $username@<Raspberry Pi IP>"
fi

# Set flash status to success
last_flash_status="success"
log "$LOG_INFO" "Flash operation completed successfully"

# Persist configuration for next run
write_config
log "$LOG_INFO" "Final configuration saved"
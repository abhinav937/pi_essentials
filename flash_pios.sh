#!/bin/bash
# Script to flash a local or downloaded Raspberry Pi OS Lite image to an SD card,
# configure SSH with public key authentication and optional password, and set an optional static IP
# Exit on any error
set -e

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check for required tools
for cmd in wget dd xz lsblk sha256sum partprobe jq openssl pv numfmt bc; do
    if ! command_exists "$cmd"; then
        echo "Error: $cmd is not installed. Please install it (e.g., 'sudo apt install $cmd')."
        exit 1
    fi
done

# Function to cleanup and exit on error
cleanup_and_exit() {
    local exit_code=$1
    local status=${2:-"failed"}
    
    echo "Flash operation $status. Cleaning up..."
    
    # Always remove decompressed image file
    if [ -f "$image_file" ]; then
        rm -f "$image_file"
        echo "Removed decompressed image: $image_file"
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
    
    exit "$exit_code"
}

# Set trap to cleanup on exit
trap 'cleanup_and_exit 1 "failed"' EXIT

# Configuration owner (prefer invoking non-root user when run with sudo)
config_owner="${SUDO_USER:-$USER}"
config_owner_home=$(getent passwd "$config_owner" | cut -d: -f6 2>/dev/null)
config_owner_home=${config_owner_home:-$HOME}

# Configuration file path: store next to this script in the project folder
script_dir="$(cd "$(dirname "$0")" && pwd)"
config_dir="$script_dir"
config_file="$config_dir/flash_pios.json"
mkdir -p "$config_dir"

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

# Get the boot device (parent device, not partition)
boot_device=$(lsblk -o NAME,MOUNTPOINTS | grep -E '[[:space:]]/(boot/firmware|/)' | head -n 1 | awk '{print $1}' | sed 's/[├─│└].*//')
boot_device="/dev/$boot_device"
if [ ! -b "$boot_device" ]; then
    echo "Warning: Could not detect boot device. Assuming none."
    boot_device=""
else
    echo "Boot device detected: $boot_device"
fi

# Automatically detect block devices (prefer removable, exclude boot device)
echo "Detecting block devices..."
mapfile -t devices < <(lsblk -J -o NAME,SIZE,RM,MODEL,MOUNTPOINTS | jq -r --arg bootdev "$boot_device" '.blockdevices[] | select(.name != $bootdev and .name != "") | select(.rm == true or .rm == "1") | "\(.name) \(.size) \(.model // "Unknown") \(.mountpoints | join(","))"' 2>/dev/null)
if [ ${#devices[@]} -eq 0 ]; then
    echo "No removable block devices found. Listing all available block devices (excluding $boot_device):"
    mapfile -t devices < <(lsblk -J -o NAME,SIZE,MODEL,MOUNTPOINTS | jq -r --arg bootdev "$boot_device" '.blockdevices[] | select(.name != $bootdev and .name != "") | "\(.name) \(.size) \(.model // "Unknown") \(.mountpoints | join(","))"' 2>/dev/null)
    if [ ${#devices[@]} -eq 0 ]; then
        echo "Error: No block devices found. Please insert an SD card."
        exit 1
    fi
fi

if [ ${#devices[@]} -eq 1 ]; then
    sd_card="/dev/${devices[0]%% *}"
    echo "Found one block device: $sd_card (${devices[0]})"
else
    echo "Available block devices (excluding boot device $boot_device):"
    for i in "${!devices[@]}"; do
        echo "[$i] ${devices[$i]}"
    done
    echo "Enter the number of the SD card device (0-${#devices[@]}) or press Enter to use [0]:"
    read -r choice
    choice=${choice:-0}
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -ge "${#devices[@]}" ]; then
        echo "Error: Invalid selection."
        exit 1
    fi
    sd_card="/dev/${devices[$choice]%% *}"
fi

# Warn if device size is unusually large (>64GB)
size=$(lsblk -b -o SIZE "$sd_card" | tail -n 1)
if [ "$size" -gt 68719476736 ]; then
    size_gb=$(echo "scale=1; $size / 1024 / 1024 / 1024" | bc -l 2>/dev/null || echo "unknown")
    echo "WARNING: $sd_card is larger than 64GB (${size_gb} GB). Are you sure this is the correct SD card? (y/N)"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# Confirm SD card erasing
echo "WARNING: All data on $sd_card will be erased. Continue? (y/N) (default: ${default_confirm_erase:-N}):"
read -r confirm
confirm=${confirm:-${default_confirm_erase:-N}}
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 1
fi

# Confirm FAT32 formatting
echo "Do you want to format $sd_card to FAT32 before flashing? (y/N) (default: ${default_confirm_format:-N}):"
read -r format_confirm
format_confirm=${format_confirm:-${default_confirm_format:-N}}
if [ "$format_confirm" = "y" ] || [ "$format_confirm" = "Y" ]; then
    echo "Formatting $sd_card to FAT32..."
    
    # Unmount any existing partitions
    sudo umount "${sd_card}"* 2>/dev/null || true
    
    # Clear partition table and create new one
    echo "Clearing partition table..."
    sudo dd if=/dev/zero of="$sd_card" bs=1M count=1 conv=notrunc
    
    # Create new partition table
    echo "Creating new partition table..."
    echo -e "o\nn\np\n1\n\n\nw" | sudo fdisk "$sd_card"
    
    # Wait for partition to be recognized
    sudo partprobe "$sd_card"
    sleep 2
    
    # Format the first partition as FAT32
if [ -b "${sd_card}1" ]; then
    echo "Formatting ${sd_card}1 as FAT32..."
    sudo mkfs.vfat -F 32 "${sd_card}1" 2>&1 | tee /tmp/mkfs_output.log
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo "FAT32 formatting completed successfully."
    else
        echo "Warning: FAT32 formatting had issues. Check /tmp/mkfs_output.log for details."
        echo "Continuing with existing format..."
    fi
else
    echo "Warning: Partition ${sd_card}1 not found. Continuing with existing format..."
fi
fi

# Final confirmation before flashing
echo "Ready to flash Raspberry Pi OS to $sd_card. Continue? (y/N) (default: ${default_confirm_flash:-N}):"
read -r flash_confirm
flash_confirm=${flash_confirm:-${default_confirm_flash:-N}}
if [ "$flash_confirm" != "y" ] && [ "$flash_confirm" != "Y" ]; then
    echo "Aborted."
    exit 1
fi

# Prompt for username and architecture
echo "Enter username for the Raspberry Pi (default: ${default_username:-pi}):"
read -r username
username=${username:-${default_username:-pi}}
echo "Enter password for user $username (leave empty for key-only authentication) (default: ${default_password:-}):"
read -r -s password
password=${password:-$default_password}
echo
echo "Choose architecture: 32 or 64 (default: ${default_arch:-64}):"
read -r arch
arch=${arch:-${default_arch:-64}}
write_config

# Prompt for static IP address
echo "Enter the static IP address for the Raspberry Pi (e.g., 192.168.0.100) or press Enter to skip (default: ${default_static_ip:-none}):"
read -r static_ip
static_ip=${static_ip:-$default_static_ip}
if [ -n "$static_ip" ]; then
    echo "Enter your network's gateway/router IP (e.g., 192.168.0.1) (default: ${default_gateway_ip:-}):"
    read -r gateway_ip
    gateway_ip=${gateway_ip:-$default_gateway_ip}
    if [ -z "$gateway_ip" ]; then
        echo "Error: Gateway IP cannot be empty if static IP is set."
        exit 1
    fi
    subnet_mask="${default_subnet_mask:-24}"
    dns_server="${default_dns_server:-8.8.8.8}"
    echo "Using subnet mask /$subnet_mask and DNS $dns_server. Edit /etc/dhcpcd.conf manually if different values are needed."
fi
write_config

# Determine which user's SSH key to use (prefer the invoking non-root user if run with sudo)
ssh_user="${SUDO_USER:-$USER}"
ssh_user_home=$(getent passwd "$ssh_user" | cut -d: -f6 2>/dev/null)
ssh_user_home=${ssh_user_home:-$HOME}

# Check for or generate SSH key pair
if [ ! -f "$ssh_user_home/.ssh/id_ed25519" ]; then
    echo "No SSH key found for $ssh_user. Generating a new ED25519 key pair..."
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" -H mkdir -p "$ssh_user_home/.ssh"
        sudo -u "$SUDO_USER" -H ssh-keygen -t ed25519 -C "$username@raspberrypi" -N "" -f "$ssh_user_home/.ssh/id_ed25519"
    else
        mkdir -p "$ssh_user_home/.ssh"
        ssh-keygen -t ed25519 -C "$username@raspberrypi" -N "" -f "$ssh_user_home/.ssh/id_ed25519"
    fi
fi
pubkey=$(cat "$ssh_user_home/.ssh/id_ed25519.pub")
if [ -z "$pubkey" ]; then
    echo "Error: Failed to read public key."
    exit 1
fi

# Prompt for local image file
echo "Enter the path to a local Raspberry Pi OS Lite image (.img or .img.xz) or press Enter to download the latest${default_local_image:+ [default: $default_local_image]}:"
read -r local_image
local_image=${local_image:-$default_local_image}
image_file="raspios-lite-latest.img"
write_config
if [ -n "$local_image" ]; then
    # Validate local image
    if [ ! -f "$local_image" ]; then
        echo "Error: Local image file $local_image does not exist."
        exit 1
    fi
    if [[ "$local_image" != *.img && "$local_image" != *.img.xz ]]; then
        echo "Error: Local image must have a .img or .img.xz extension."
        exit 1
    fi
    echo "Using local image: $local_image"
    if [[ "$local_image" == *.img.xz ]]; then
        echo "Decompressing local image $local_image..."
        image_file="${local_image%.xz}"
        
        # Get compressed file size for progress display
        compressed_size=$(stat -c %s "$local_image" 2>/dev/null || stat -f %z "$local_image" 2>/dev/null || echo "0")
        
        if [ "$compressed_size" -gt 0 ]; then
            echo "Compressed size: $(numfmt --to=iec-i --suffix=B $compressed_size)"
            echo "Decompressing with progress..."
            
            if command_exists pv; then
                # Use pv to show decompression progress
                echo "Using pv for decompression progress..."
                echo "pv decompression command: pv -s $compressed_size $local_image | xz -dc > $image_file"
                
                # Force unbuffered output and show progress
                echo "Starting decompression with progress display..."
                echo "Progress: ["
                
                # Use pv with explicit progress display and force unbuffered output
                if ! stdbuf -oL pv -s "$compressed_size" -p -t -e -r -f -B 65536 "$local_image" 2>/dev/tty | xz -dc > "$image_file"; then
                    echo "Error: Failed to decompress $local_image."
                    cleanup_and_exit 1 "failed"
                fi
                echo "] Decompression completed successfully!"
            else
                # Fallback to xz with verbose output
                if ! xz -dkv "$local_image"; then
                    echo "Error: Failed to decompress $local_image."
                    cleanup_and_exit 1 "failed"
                fi
            fi
        else
            # Fallback if size detection fails
            if ! xz -dk "$local_image"; then
                echo "Error: Failed to decompress $local_image."
                cleanup_and_exit 1 "failed"
            fi
        fi
        
        echo "Decompression completed: $image_file"
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
    echo "Downloading the latest Raspberry Pi OS Lite ($arch-bit)..."
    wget -O raspios-lite-latest.img.xz "$download_url" --show-progress
    wget -O raspios-lite-latest.sha256 "$checksum_url" --show-progress
    # Verify the download
    if [ ! -f "raspios-lite-latest.img.xz" ] || [ ! -f "raspios-lite-latest.sha256" ]; then
        echo "Error: Download failed."
        exit 1
    fi
    # Rename the downloaded file to match the name in the checksum file (if provided)
    expected_xz=$(awk '{print $2}' raspios-lite-latest.sha256 | tr -d '\r')
    downloaded_xz="raspios-lite-latest.img.xz"
    if [ -n "$expected_xz" ]; then
        mv -f "$downloaded_xz" "$expected_xz"
        downloaded_xz="$expected_xz"
    fi
    echo "Verifying image integrity..."
    if ! sha256sum -c raspios-lite-latest.sha256; then
        echo "Error: Image verification failed."
        exit 1
    fi
    # Decompress the image
    echo "Decompressing $downloaded_xz..."
    xz -dk "$downloaded_xz"
    image_file="${downloaded_xz%.xz}"
fi

# Unmount all partitions of the SD card
echo "Unmounting SD card partitions..."
sudo umount "${sd_card}"* 2>/dev/null || true

# Write the image to the SD card with pv for progress bar
echo "Writing $image_file to $sd_card..."
echo "This may take several minutes. Please wait..."

# Check if image file exists and has size
if [ ! -f "$image_file" ]; then
    echo "Error: Image file $image_file not found!"
    cleanup_and_exit 1 "failed"
fi

image_size=$(stat -c %s "$image_file" 2>/dev/null || stat -f %z "$image_file" 2>/dev/null || echo "0")
if [ "$image_size" -eq 0 ]; then
    echo "Error: Image file $image_file has zero size!"
    cleanup_and_exit 1 "failed"
fi

echo "Image size: $(numfmt --to=iec-i --suffix=B $image_size)"
echo "Starting write operation..."

# Use pv with better progress display
if command_exists pv; then
    echo "Using pv for progress display..."
    echo "pv version: $(pv --version | head -1)"
    echo "pv command: pv -s $image_size -p -t -e -r -f -B 65536 $image_file"
    echo "Starting pv transfer..."
    echo "Progress: ["

    # Force progress output and reduce buffering
    if ! stdbuf -oL pv -s "$image_size" -p -t -e -r -f -B 65536 "$image_file" 2>/dev/tty | sudo dd bs=4M of="$sd_card" conv=fsync; then
        echo "Error: Failed to write image to SD card!"
        cleanup_and_exit 1 "failed"
    fi
    echo "] Write completed successfully!"
else
    echo "pv not available, using dd with progress..."
    sudo dd bs=4M if="$image_file" of="$sd_card" conv=fsync status=progress
fi

# Check if write was successful
if [ $? -ne 0 ]; then
    echo "Error: Failed to write image to SD card!"
    cleanup_and_exit 1 "failed"
fi

# Sync to ensure all data is written
sync

# Refresh partition table
echo "Refreshing partition table..."
if ! sudo partprobe "$sd_card"; then
    echo "Warning: Failed to refresh partition table. Waiting 2 seconds..."
    sleep 2
fi
sudo udevadm settle || sleep 2

# Mount the boot and rootfs partitions
echo "Mounting SD card partitions..."
boot_mnt=$(mktemp -d)
root_mnt=$(mktemp -d)
if [ ! -b "${sd_card}1" ]; then
    echo "Error: Partition ${sd_card}1 not found. Image may not have flashed correctly."
    echo "Waiting for partitions to appear..."
    sleep 3
fi
if [ ! -b "${sd_card}1" ]; then
    echo "Error: Partition ${sd_card}1 not found after waiting. Image may not have flashed correctly."
    exit 1
fi
if ! sudo mount "${sd_card}1" "$boot_mnt"; then
    echo "Error: Failed to mount ${sd_card}1"
    exit 1
fi
if [ ! -b "${sd_card}2" ]; then
    echo "Error: Partition ${sd_card}2 not found. Image may not have flashed correctly."
    echo "Waiting for partitions to appear..."
    sleep 3
fi
if [ ! -b "${sd_card}2" ]; then
    echo "Error: Partition ${sd_card}2 not found after waiting. Image may not have flashed correctly."
    exit 1
fi
if ! sudo mount "${sd_card}2" "$root_mnt"; then
    echo "Error: Failed to mount ${sd_card}2"
    exit 1
fi

# Enable SSH
echo "Enabling SSH..."
sudo touch "$boot_mnt/ssh"

# Check if username already exists in /etc/passwd
if grep -q "^$username:" "$root_mnt/etc/passwd"; then
    echo "User $username already exists in the image. Updating existing user configuration..."
    # Remove existing user entries
    sudo sed -i "/^$username:/d" "$root_mnt/etc/passwd"
    sudo sed -i "/^$username:/d" "$root_mnt/etc/group"
    sudo sed -i "/^$username:/d" "$root_mnt/etc/shadow"
    echo "Removed existing user $username entries."
fi

# Create user configuration
echo "Configuring user $username..."
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

# Configure SSH server for security
echo "Configuring SSH server..."
sudo sed -i 's/#PermitRootLogin .*/PermitRootLogin no/' "$root_mnt/etc/ssh/sshd_config"
echo "AllowUsers $username" | sudo tee -a "$root_mnt/etc/ssh/sshd_config" >/dev/null
if [ -z "$password" ]; then
    sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' "$root_mnt/etc/ssh/sshd_config"
fi

# Configure static IP (if provided)
if [ -n "$static_ip" ]; then
    echo "Configuring static IP $static_ip..."
    if grep -q "interface eth0" "$root_mnt/etc/dhcpcd.conf"; then
        echo "Warning: Existing eth0 configuration found in dhcpcd.conf. Skipping static IP setup."
    else
        echo -e "\ninterface eth0\nstatic ip_address=$static_ip/$subnet_mask\nstatic routers=$gateway_ip\nstatic domain_name_servers=$dns_server" | sudo tee -a "$root_mnt/etc/dhcpcd.conf" >/dev/null
    fi
fi

# Unmount partitions
echo "Unmounting partitions..."
sudo umount "$boot_mnt" "$root_mnt" || true
rmdir "$boot_mnt" "$root_mnt"

# Eject the SD card
echo "Ejecting SD card..."
sudo eject "$sd_card" || true

# Clean up
echo "Cleaning up..."
echo "Removing temporary files..."

# Always remove decompressed image file, whether local or downloaded
if [ -f "$image_file" ]; then
    rm -f "$image_file"
    echo "Removed decompressed image: $image_file"
fi

# Clean up downloaded files if they exist
if [ -z "$local_image" ]; then
    # Clean up downloaded artifacts regardless of renamed filename
    rm -f "raspios-lite-latest.img.xz" "raspios-lite-latest.sha256"
    if [ -n "$downloaded_xz" ]; then
        rm -f "$downloaded_xz"
    fi
fi

# Clean up any other temporary files that might exist
rm -f "raspios-lite-latest.img" "*.log" "*.tmp" 2>/dev/null || true

echo "Cleanup completed. Only original image files remain."

# Remove trap since we're exiting normally
trap - EXIT

echo "SD card has been formatted, flashed, and configured successfully!"
echo "You can now remove the SD card and insert it into your Raspberry Pi."
if [ -n "$static_ip" ]; then
    echo "Try SSH with: ssh $username@$static_ip"
else
    echo "Try SSH with: ssh $username@<Raspberry Pi IP>"
fi

# Set flash status to success
last_flash_status="success"

# Persist configuration for next run
write_config
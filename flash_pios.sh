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
for cmd in wget dd xz lsblk sha256sum partprobe jq openssl pv; do
    if ! command_exists "$cmd"; then
        echo "Error: $cmd is not installed. Please install it (e.g., 'sudo apt install $cmd')."
        exit 1
    fi
done

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
    echo "WARNING: $sd_card is larger than 64GB ($size bytes). Are you sure this is the correct SD card? (y/N)"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# Confirm SD card formatting
echo "WARNING: All data on $sd_card will be erased. Continue? (y/N)"
read -r confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 1
fi

# Prompt for username and architecture
echo "Enter username for the Raspberry Pi (default: pi):"
read -r username
username=${username:-pi}
echo "Enter password for user $username (leave empty for key-only authentication):"
read -r -s password
echo
echo "Choose architecture: 32 or 64 (default: 64):"
read -r arch
arch=${arch:-64}

# Prompt for static IP address
echo "Enter the static IP address for the Raspberry Pi (e.g., 192.168.0.100) or press Enter to skip:"
read -r static_ip
if [ -n "$static_ip" ]; then
    echo "Enter your network's gateway/router IP (e.g., 192.168.0.1):"
    read -r gateway_ip
    if [ -z "$gateway_ip" ]; then
        echo "Error: Gateway IP cannot be empty if static IP is set."
        exit 1
    fi
    subnet_mask="24"
    dns_server="8.8.8.8"
    echo "Using subnet mask /$subnet_mask and DNS $dns_server. Edit /etc/dhcpcd.conf manually if different values are needed."
fi

# Check for or generate SSH key pair
if [ ! -f ~/.ssh/id_ed25519 ]; then
    echo "No SSH key found. Generating a new ED25519 key pair..."
    ssh-keygen -t ed25519 -C "$username@raspberrypi" -N "" -f ~/.ssh/id_ed25519
fi
pubkey=$(cat ~/.ssh/id_ed25519.pub)
if [ -z "$pubkey" ]; then
    echo "Error: Failed to read public key."
    exit 1
fi

# Prompt for local image file
echo "Enter the path to a local Raspberry Pi OS Lite image (.img or .img.xz) or press Enter to download the latest:"
read -r local_image
image_file="raspios-lite-latest.img"
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
        if ! xz -dc "$local_image" > "$image_file"; then
            echo "Error: Failed to decompress $local_image."
            exit 1
        fi
    else
        if ! cp "$local_image" "$image_file"; then
            echo "Error: Failed to copy $local_image."
            exit 1
        fi
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
    echo "Verifying image integrity..."
    if ! sha256sum -c raspios-lite-latest.sha256; then
        echo "Error: Image verification failed."
        exit 1
    fi
    # Decompress the image
    echo "Decompressing raspios-lite-latest.img.xz..."
    xz -dk "raspios-lite-latest.img.xz"
fi

# Unmount all partitions of the SD card
echo "Unmounting SD card partitions..."
sudo umount "${sd_card}"* 2>/dev/null || true

# Write the image to the SD card with pv for progress bar
echo "Writing $image_file to $sd_card..."
image_size=$(stat -f %z "$image_file" 2>/dev/null || stat -c %s "$image_file") # macOS or Linux
sudo pv -s "$image_size" "$image_file" | sudo dd bs=4M of="$sd_card" conv=fsync

# Sync to ensure all data is written
sync

# Refresh partition table
echo "Refreshing partition table..."
if ! sudo partprobe "$sd_card"; then
    echo "Warning: Failed to refresh partition table. Waiting 2 seconds..."
    sleep 2
fi

# Mount the boot and rootfs partitions
echo "Mounting SD card partitions..."
boot_mnt=$(mktemp -d)
root_mnt=$(mktemp -d)
if [ ! -b "${sd_card}1" ]; then
    echo "Error: Partition ${sd_card}1 not found. Image may not have flashed correctly."
    exit 1
fi
if ! sudo mount "${sd_card}1" "$boot_mnt"; then
    echo "Error: Failed to mount ${sd_card}1"
    exit 1
fi
if [ ! -b "${sd_card}2" ]; then
    echo "Error: Partition ${sd_card}2 not found. Image may not have flashed correctly."
    exit 1
}
if ! sudo mount "${sd_card}2" "$root_mnt"; then
    echo "Error: Failed to mount ${sd_card}2"
    exit 1
fi

# Enable SSH
echo "Enabling SSH..."
sudo touch "$boot_mnt/ssh"

# Check if username already exists in /etc/passwd
if grep -q "^$username:" "$root_mnt/etc/passwd"; then
    echo "Error: User $username already exists in the image."
    exit 1
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
rm -f "$image_file"
[ -z "$local_image" ] && rm -f "raspios-lite-latest.img.xz" "raspios-lite-latest.sha256"

echo "SD card has been formatted, flashed, and configured successfully!"
echo "You can now remove the SD card and insert it into your Raspberry Pi."
if [ -n "$static_ip" ]; then
    echo "Try SSH with: ssh $username@$static_ip"
else
    echo "Try SSH with: ssh $username@<Raspberry Pi IP>"
fi
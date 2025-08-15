# Raspberry Pi OS Flashing Script

A bash script for flashing Raspberry Pi OS images to SD cards with SSH setup, static IP configuration, and Wi-Fi support.

## Features

- Automatic image download (32-bit or 64-bit)
- Local image support
- Interactive SD card selection
- SSH key generation and configuration
- Static IP setup (Ethernet/Wi-Fi)
- Wi-Fi configuration
- Progress monitoring

## Prerequisites

```bash
# Ubuntu/Debian
sudo apt install wget dd xz-utils lsblk sha256sum parted jq openssl pv numfmt bc

# macOS
brew install wget coreutils xz jq openssl pv numfmt bc
```

## Usage

```bash
chmod +x flash_pios.sh
sudo ./flash_pios.sh
```

The script will guide you through:
1. SD card selection
2. User configuration
3. Network setup (optional)
4. Image selection
5. Confirmation

## Configuration

Settings are saved in `flash_pios.json` for future runs.

## Troubleshooting

- **SD card not detected**: Ensure proper insertion and USB connection
- **Permission errors**: Run with `sudo`
- **Static IP issues**: Check interface selection and router settings
- **Logs**: Check `flash_pios.log` for detailed information

## License

MIT License - see [LICENSE](LICENSE) file.

---

**Warning**: This script performs low-level device operations. Always verify device selection and backup important data.
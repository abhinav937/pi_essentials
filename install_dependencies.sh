#!/bin/bash
# Installation script for flash_pios.sh dependencies
# This script installs all required tools on various operating systems

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local status=$1
    local message=$2
    case $status in
        "info") echo -e "${BLUE}[INFO]${NC} $message" ;;
        "success") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
        "warning") echo -e "${YELLOW}[WARNING]${NC} $message" ;;
        "error") echo -e "${RED}[ERROR]${NC} $message" ;;
    esac
}

# Function to detect operating system
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            echo "$ID"
        elif command -v lsb_release >/dev/null 2>&1; then
            lsb_release -si | tr '[:upper:]' '[:lower:]'
        else
            echo "linux"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
        echo "windows"
    else
        echo "unknown"
    fi
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install packages on Ubuntu/Debian
install_debian() {
    print_status "info" "Installing packages on Ubuntu/Debian..."
    
    # Update package list
    sudo apt update
    
    # Install required packages
    sudo apt install -y \
        wget \
        dd \
        xz-utils \
        lsblk \
        sha256sum \
        parted \
        jq \
        openssl \
        pv \
        numfmt \
        bc \
        curl
    
    print_status "success" "Ubuntu/Debian packages installed successfully!"
}

# Function to install packages on CentOS/RHEL/Fedora
install_redhat() {
    local os=$(detect_os)
    print_status "info" "Installing packages on $os..."
    
    if [[ "$os" == "fedora" ]]; then
        # Fedora uses dnf
        sudo dnf update -y
        sudo dnf install -y \
            wget \
            dd \
            xz \
            lsblk \
            sha256sum \
            parted \
            jq \
            openssl \
            pv \
            numfmt \
            bc \
            curl
    else
        # CentOS/RHEL use yum
        sudo yum update -y
        sudo yum install -y \
            wget \
            dd \
            xz \
            lsblk \
            sha256sum \
            parted \
            jq \
            openssl \
            pv \
            numfmt \
            bc \
            curl
    fi
    
    print_status "success" "$os packages installed successfully!"
}

# Function to install packages on Arch Linux
install_arch() {
    print_status "info" "Installing packages on Arch Linux..."
    
    sudo pacman -Sy --noconfirm \
        wget \
        coreutils \
        xz \
        util-linux \
        parted \
        jq \
        openssl \
        pv \
        bc \
        curl
    
    print_status "success" "Arch Linux packages installed successfully!"
}

# Function to install packages on macOS
install_macos() {
    print_status "info" "Installing packages on macOS..."
    
    # Check if Homebrew is installed
    if ! command_exists brew; then
        print_status "warning" "Homebrew not found. Installing Homebrew first..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # Add Homebrew to PATH if needed
        if [[ "$SHELL" == "/bin/zsh" ]]; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ "$SHELL" == "/bin/bash" ]]; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.bash_profile
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
    fi
    
    # Install required packages
    brew install \
        wget \
        coreutils \
        xz \
        jq \
        openssl \
        pv \
        bc \
        curl
    
    print_status "success" "macOS packages installed successfully!"
}

# Function to install packages on Alpine Linux
install_alpine() {
    print_status "info" "Installing packages on Alpine Linux..."
    
    sudo apk update
    sudo apk add \
        wget \
        coreutils \
        xz \
        lsblk \
        parted \
        jq \
        openssl \
        pv \
        bc \
        curl
    
    print_status "success" "Alpine Linux packages installed successfully!"
}

# Function to verify installation
verify_installation() {
    print_status "info" "Verifying installation..."
    
    local missing_tools=()
    local required_tools=("wget" "dd" "xz" "lsblk" "sha256sum" "parted" "jq" "openssl" "pv" "numfmt" "bc")
    
    for tool in "${required_tools[@]}"; do
        if command_exists "$tool"; then
            print_status "success" "✓ $tool is available"
        else
            print_status "error" "✗ $tool is missing"
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -eq 0 ]; then
        print_status "success" "All required tools are installed and available!"
        return 0
    else
        print_status "error" "Missing tools: ${missing_tools[*]}"
        print_status "warning" "Some tools may have different names on your system. Check the manual installation guide."
        return 1
    fi
}

# Function to show manual installation guide
show_manual_guide() {
    print_status "info" "Manual installation guide:"
    echo ""
    echo "If automatic installation failed, you can install the tools manually:"
    echo ""
    echo "Required tools:"
    echo "  - wget: HTTP download utility"
    echo "  - dd: Data duplicator (usually pre-installed)"
    echo "  - xz: XZ compression utility"
    echo "  - lsblk: List block devices"
    echo "  - sha256sum: SHA256 checksum utility"
    echo "  - parted: Partition manipulation tool"
    echo "  - jq: JSON processor"
    echo "  - openssl: SSL/TLS toolkit"
    echo "  - pv: Pipe viewer (progress bar)"
    echo "  - numfmt: Number formatting utility"
    echo "  - bc: Basic calculator"
    echo ""
    echo "Installation commands by distribution:"
    echo ""
    echo "Ubuntu/Debian:"
    echo "  sudo apt install wget xz-utils lsblk parted jq openssl pv numfmt bc"
    echo ""
    echo "CentOS/RHEL/Fedora:"
    echo "  sudo yum install wget xz lsblk parted jq openssl pv numfmt bc"
    echo "  # or for Fedora:"
    echo "  sudo dnf install wget xz lsblk parted jq openssl pv numfmt bc"
    echo ""
    echo "Arch Linux:"
    echo "  sudo pacman -S wget xz util-linux parted jq openssl pv bc"
    echo ""
    echo "macOS (with Homebrew):"
    echo "  brew install wget xz jq openssl pv bc"
    echo ""
    echo "Alpine Linux:"
    echo "  sudo apk add wget xz lsblk parted jq openssl pv bc"
}

# Main execution
main() {
    echo "=========================================="
    echo "  flash_pios.sh Dependencies Installer"
    echo "=========================================="
    echo ""
    
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        print_status "warning" "Running as root. This is not recommended."
        read -p "Continue anyway? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Detect operating system
    local os=$(detect_os)
    print_status "info" "Detected operating system: $os"
    
    # Install packages based on OS
    case $os in
        "ubuntu"|"debian"|"linuxmint"|"pop")
            install_debian
            ;;
        "centos"|"rhel"|"fedora"|"rocky"|"alma")
            install_redhat
            ;;
        "arch"|"manjaro"|"endeavouros")
            install_arch
            ;;
        "macos")
            install_macos
            ;;
        "alpine")
            install_alpine
            ;;
        "windows")
            print_status "error" "Windows detected. Please use WSL or Git Bash."
            print_status "info" "Install WSL2 and run this script from within WSL."
            exit 1
            ;;
        *)
            print_status "warning" "Unknown operating system: $os"
            print_status "info" "Attempting generic Linux installation..."
            install_debian
            ;;
    esac
    
    echo ""
    
    # Verify installation
    if verify_installation; then
        echo ""
        print_status "success" "Installation completed successfully!"
        print_status "info" "You can now run flash_pios.sh"
    else
        echo ""
        print_status "warning" "Installation completed with some issues."
        show_manual_guide
    fi
}

# Run main function
main "$@"

#!/bin/bash

echo "Testing pv progress display..."
echo "================================"

# Check if pv is installed
if command -v pv >/dev/null 2>&1; then
    echo "✓ pv is installed: $(pv --version | head -1)"
else
    echo "✗ pv is not installed. Install with: sudo apt install pv"
    exit 1
fi

echo ""
echo "1. Testing basic pv functionality:"
echo "Creating a test file..."
dd if=/dev/zero of=test_file.bin bs=1M count=100 2>/dev/null

echo ""
echo "2. Testing pv with dd (like in our script):"
echo "Copying with progress bar..."
pv -s 100M test_file.bin | dd of=test_output.bin bs=1M 2>/dev/null

echo ""
echo "3. Testing pv with xz compression (like decompression in our script):"
echo "Compressing with progress bar..."
pv -s 100M test_file.bin | xz -c > test_file.xz

echo ""
echo "4. Testing pv with xz decompression (like in our script):"
echo "Decompressing with progress bar..."
pv -s $(stat -c %s test_file.xz) test_file.xz | xz -dc > test_decompressed.bin

echo ""
echo "5. Testing pv options we use in the script:"
echo "pv -s 100M -p -t -e -r test_file.bin | dd of=test_final.bin bs=1M"
pv -s 100M -p -t -e -r test_file.bin | dd of=test_final.bin bs=1M 2>/dev/null

echo ""
echo "6. Cleanup test files..."
rm -f test_file.bin test_output.bin test_file.xz test_decompressed.bin test_final.bin

echo ""
echo "Test completed! If you saw progress bars above, pv is working correctly."
echo "If you didn't see progress bars, there might be an issue with your terminal or pv installation."

#!/usr/bin/env bash
set -u

PASS="[PASS]"
WARN="[WARN]"
FAIL="[FAIL]"
INFO="[INFO]"

echo "=========================================================="
echo "   Raspberry Pi 5 (4GB) Automated Hardware Diagnostic"
echo "=========================================================="

# 1. Board & Firmware
echo -e "\n--- 1. Board & Bootloader ---"
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")
echo "$INFO Model: $MODEL"
if [[ "$MODEL" == *"Raspberry Pi 5"* ]]; then
    echo "$PASS Confirmed Raspberry Pi 5 hardware"
else
    echo "$WARN Unexpected board model string"
fi
vcgencmd bootloader_version | head -n 2 | sed "s/^/$INFO /"

# 2. CPU & RAM
echo -e "\n--- 2. CPU & Memory ---"
CORES=$(nproc)
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/ {print $2}')
echo "$INFO Detected CPU Cores: $CORES | Usable RAM: ${TOTAL_MEM_MB} MB"
[[ "$CORES" -eq 4 ]] && echo "$PASS All 4 Cortex-A76 cores online" || echo "$FAIL Expected 4 cores, saw $CORES"
[[ "$TOTAL_MEM_MB" -ge 3500 && "$TOTAL_MEM_MB" -le 4200 ]] && echo "$PASS 4GB RAM module verified" || echo "$WARN Unexpected RAM size (${TOTAL_MEM_MB} MB)"

# 3. Power & Throttling
echo -e "\n--- 3. Power & Throttling ---"
THROTTLED=$(vcgencmd get_throttled | cut -d= -f2)
TEMP=$(vcgencmd measure_temp | cut -d= -f2)
echo "$INFO Current SoC Temperature: $TEMP"
if [[ "$THROTTLED" == "0x0" ]]; then
    echo "$PASS Power delivery clean (throttled=$THROTTLED)"
else
    echo "$FAIL Throttling/undervoltage flag detected: $THROTTLED (Check 5V/5A PSU)"
fi

# 4. PWM Cooling Fan
echo -e "\n--- 4. Active Cooler / Fan Header ---"
FAN_RPM=$(cat /sys/devices/platform/cooling_fan/hwmon/*/fan1_input 2>/dev/null || echo "N/A")
if [[ "$FAN_RPM" != "N/A" ]]; then
    echo "$PASS PWM Fan detected (Current speed: ${FAN_RPM} RPM)"
else
    echo "$INFO No PWM fan tach signal detected (normal if passive/no official cooler)"
fi

# 5. Storage, PCIe & USB Buses
echo -e "\n--- 5. Storage, PCIe & USB Controllers ---"
if lsblk -d -o NAME,SIZE,MODEL | grep -q "mmcblk0"; then
    echo "$PASS microSD card slot active ($(lsblk -dn -o SIZE /dev/mmcblk0))"
else
    echo "$WARN No microSD card detected in slot"
fi

if lspci 2>/dev/null | grep -q .; then
    echo "$PASS PCIe bus active:"
    lspci | sed "s/^/       /"
else
    echo "$INFO PCIe bus idle (no NVMe/PCIe HAT attached)"
fi

USB3_COUNT=$(lsusb -t 2>/dev/null | grep -c "5000M" || true)
echo "$INFO Active 5Gbps (USB 3.0) root hubs/links: $USB3_COUNT"
lsusb | sed "s/^/       /"

# 6. Networking (Ethernet, Wi-Fi, Bluetooth)
echo -e "\n--- 6. Networking & Wireless ---"
ETH_STATE=$(cat /sys/class/net/eth0/operstate 2>/dev/null || echo "missing")
if [[ "$ETH_STATE" == "up" ]]; then
    ETH_SPEED=$(cat /sys/class/net/eth0/speed 2>/dev/null || echo "unknown")
    echo "$PASS Ethernet UP at ${ETH_SPEED} Mbps"
else
    echo "$WARN Ethernet interface state: $ETH_STATE (plug in cable to test 1000 Mbps)"
fi

if rfkill list wifi | grep -q "Wireless LAN"; then
    WIFI_SCAN=$(nmcli -t -f SSID dev wifi list 2>/dev/null | head -n 3 | paste -sd "," -)
    echo "$PASS Wi-Fi adapter active (Visible SSIDs: ${WIFI_SCAN:-none in range})"
else
    echo "$FAIL Wi-Fi adapter not detected"
fi

if hciconfig 2>/dev/null | grep -q "hci0" || bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; then
    echo "$PASS Bluetooth 5.0 controller active"
else
    echo "$WARN Bluetooth controller not powered or missing"
fi

# 7. Display, Camera (MIPI), RTC & GPIO Buses
echo -e "\n--- 7. HDMI, MIPI Cameras, RTC & GPIO Buses ---"
for conn in /sys/class/drm/card*-HDMI-A-*; do
    if [[ -f "$conn/status" ]]; then
        PORT_NAME=$(basename "$conn")
        STATUS=$(cat "$conn/status")
        echo "$INFO $PORT_NAME: $STATUS"
    fi
done

if command -v rpicam-still >/dev/null 2>&1; then
    CAM_OUT=$(rpicam-still --list-cameras 2>&1)
    if echo "$CAM_OUT" | grep -q "Available cameras"; then
        echo "$PASS MIPI Camera detected"
    else
        echo "$INFO No MIPI camera connected on CAM/DISP 0 or 1"
    fi
fi

if [[ -e /dev/rtc0 ]]; then
    echo "$PASS Hardware RTC (/dev/rtc0) present: $(sudo hwclock -r 2>/dev/null || echo 'battery not set')"
else
    echo "$FAIL Hardware RTC device missing"
fi

echo "$INFO Enabled GPIO buses: $(ls /dev/i2c* /dev/spidev* 2>/dev/null | xargs || echo 'None (enable in raspi-config)')"

# 8. Optional 30-Second CPU/RAM Stress Test
echo -e "\n--- 8. Quick 30s Load & Thermal Stress Test ---"
read -r -p "Run a 30-second 4-core CPU/RAM stress test now? [y/N]: " RUN_STRESS
if [[ "$RUN_STRESS" =~ ^[Yy]$ ]]; then
    if ! command -v stress-ng >/dev/null 2>&1; then
        echo "$INFO Installing stress-ng..."
        sudo apt-get update -qq && sudo apt-get install -y -qq stress-ng
    fi
    echo "$INFO Running stress-ng for 30 seconds..."
    stress-ng --cpu 4 --vm 2 --vm-bytes 1G --timeout 30s --metrics-brief
    echo "$INFO Post-stress Temp: $(vcgencmd measure_temp | cut -d= -f2) | Throttled: $(vcgencmd get_throttled | cut -d= -f2)"
else
    echo "$INFO Skipping stress test."
fi

echo -e "\n=========================================================="
echo "   Diagnostic Complete"
echo "=========================================================="
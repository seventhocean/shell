#!/bin/bash

INTERFACE="ens192"
FILTER="net 192.168.10.0/24 or net 192.168.20.0/24"
OUTPUT_DIR="/mnt/deepflow_pcap"
DATE=$(date +"%Y%m%d_%H%M%S")
PCAP_FILE="$OUTPUT_DIR/capture_$DATE.pcap"

mkdir -p "$OUTPUT_DIR"

/usr/bin/timeout 60 \
    /usr/sbin/tcpdump -i "$INTERFACE" \
                      -s 0 \
                      -C 1000 \
                      -w "$PCAP_FILE" \
                      "$FILTER"

echo "$(date): Capture finished -> $PCAP_FILE (size: $(stat -c%s "$PCAP_FILE" 2>/dev/null || echo 0) bytes)" >> /mnt/deepflow_pcap/capture.log

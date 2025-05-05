#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

echo "Starting KasmVNC Provisioning Script..."

# --- KasmVNC Installation ---
KASM_VERSION="1.15.0"
KASM_INSTALL_DIR="/opt/kasm"
DEB_URL="https://kasm-static.s3.amazonaws.com/kasmvnc/kasmvnc_server_jammy_${KASM_VERSION}_amd64.deb"
DEB_FILENAME="kasmvnc_server_jammy_${KASM_VERSION}_amd64.deb"

echo "Downloading KasmVNC Server..."
# Use curl with options for robustness: -f (fail fast), -L (follow redirects), -o (output file)
curl -fLo "/tmp/${DEB_FILENAME}" "${DEB_URL}"

echo "Installing KasmVNC Server..."
# Install the downloaded .deb package and automatically handle dependencies
apt-get update
apt-get install -y --no-install-recommends "/tmp/${DEB_FILENAME}"

echo "Cleaning up downloaded KasmVNC deb file..."
rm "/tmp/${DEB_FILENAME}"

# --- KasmVNC Configuration ---
echo "Configuring KasmVNC..."

# Create KasmVNC configuration directory if it doesn't exist
mkdir -p /etc/kasmvnc/

# Create kasmvnc.yaml configuration file
# Note: Using simple user/pass for example. Secure appropriately for real use.
# Important: Set ssl_cert and ssl_key to use Vast.ai provided certs
cat <<EOF > /etc/kasmvnc/kasmvnc.yaml
logging:
  log_writer_name: "stdout" # Log to stdout to be caught by supervisor/docker logs

auth:
  type: "password"
  username: "kasm_user"
  password: "kasm_password" # CHANGE THIS to a secure password or use env var

ssl:
  cert: "/etc/ssl/certs/vast_ssl.crt" # Use Vast.ai provided cert
  key: "/etc/ssl/private/vast_ssl.key" # Use Vast.ai provided key

# Optional: Session resource limits (adjust as needed)
# session_limits:
#   cpu_limit: "4"
#   memory_limit: "8G"
#   storage_limit: "20G"
EOF

# Set permissions for the config file
chmod 644 /etc/kasmvnc/kasmvnc.yaml

# --- Supervisor Configuration for KasmVNC ---
echo "Configuring Supervisor for KasmVNC..."

# Create supervisor config file for KasmVNC
# Ensure it runs AFTER the vastai_tools service (which provides certs/portal config tool)
cat <<EOF > /etc/supervisor/conf.d/kasmvnc.conf
[program:kasmvnc]
command=/usr/bin/kasmvncserver --config /etc/kasmvnc/kasmvnc.yaml
directory=/tmp
autostart=true
autorestart=true
startretries=3
startsecs=5
stopwaitsecs=10
user=root
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=950
EOF

# --- Update Instance Portal ---
echo "Adding KasmVNC link to Instance Portal..."

# Define the KasmVNC service details in JSON format for the portal tool
# Port 6901 is KasmVNC's default HTTPS port
KASM_PORTAL_JSON='{"kasm": {"name": "Kasm Desktop", "port": 6901, "proto": "https"}}'

# Use the vastai tool to add this configuration to the portal
# The tool handles merging with existing configurations (like Jupyter)
if command -v vastai-set-portal-config &> /dev/null; then
    echo "Attempting to add Kasm config: ${KASM_PORTAL_JSON}"
    vastai-set-portal-config --add "${KASM_PORTAL_JSON}"
    echo "vastai-set-portal-config command executed."
else
    echo "WARNING: vastai-set-portal-config command not found. Cannot update Instance Portal."
fi

# --- Final Steps ---
# No need to explicitly reload supervisor here, entrypoint likely handles it,
# or the new conf file will be picked up on next start/restart.

echo "KasmVNC Provisioning Script Finished."

# Exit with 0 to indicate success
exit 0
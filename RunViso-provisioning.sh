#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
# Exit on unset variables to catch potential errors.
# Pipefail ensures that a pipeline command returns a non-zero status if any command fails
set -euo pipefail

# --- Logging Setup ---
# Log everything to stdout/stderr to be captured by Docker/Vast.ai logs
log() {
    # Use >&2 to ensure logs go to stderr, often better for error logs
    echo "$(date '+%Y-%m-%d %H:%M:%S') [Provisioning]: $1" >&2
}

log "Starting KasmVNC Provisioning Script..."

# --- Configuration ---
# Allow overriding password via environment variable for better security
KASM_USER="kasm_user"
KASM_PASSWORD="${KASM_VNC_PASSWORD:-kasm_password}" # Default to 'kasm_password' if env var not set
KASM_VERSION="1.15.0" # Pin version for reproducibility
KASM_INSTALL_DIR="/opt/kasm" # Standard install location
KASM_CONFIG_DIR="/etc/kasmvnc"
KASM_CONFIG_FILE="${KASM_CONFIG_DIR}/kasmvnc.yaml"
KASM_SUPERVISOR_CONF="/etc/supervisor/conf.d/kasmvnc.conf"
KASM_PORTAL_NAME="Kasm Desktop"
KASM_INTERNAL_PORT="6901" # Default KasmVNC HTTPS port
KASM_INTERNAL_PROTO="https"

# Vast.ai provided SSL certificate and key paths
VAST_SSL_CERT="/etc/ssl/certs/vast_ssl.crt"
VAST_SSL_KEY="/etc/ssl/private/vast_ssl.key"

# Construct Deb URL and Filename
DEB_FILENAME="kasmvnc_server_jammy_${KASM_VERSION}_amd64.deb"
DEB_URL="https://kasm-static.s3.amazonaws.com/kasmvnc/kasmvnc_server_jammy_${KASM_VERSION}_amd64.deb"
TEMP_DEB_PATH="/tmp/${DEB_FILENAME}"

# --- Dependency Check ---
log "Checking for required commands (curl, apt-get)..."
if ! command -v curl &> /dev/null; then
    log "Error: 'curl' command not found. Cannot download KasmVNC."
    exit 1
fi
if ! command -v apt-get &> /dev/null; then
    log "Error: 'apt-get' command not found. Cannot install KasmVNC."
    exit 1
fi
log "Required commands found."

# --- KasmVNC Installation ---
log "Starting KasmVNC v${KASM_VERSION} installation..."

log "Download URL: ${DEB_URL}"
log "Temporary download path: ${TEMP_DEB_PATH}"

log "Downloading KasmVNC Server..."
# Use curl with explicit error checking
# -f: Fail silently (no HTML output) on HTTP errors, but return error code
# -L: Follow redirects
# -s: Silent mode (hide progress meter)
# -S: Show error message if -s is used and it fails
# -o: Output file
if ! curl -fLsSo "${TEMP_DEB_PATH}" "${DEB_URL}"; then
    log "Error: Failed to download KasmVNC package from ${DEB_URL}. curl exit code: $?. Check URL and network connectivity."
    # Attempt to clean up potentially incomplete download
    rm -f "${TEMP_DEB_PATH}"
    exit 1
fi
log "Download complete. File saved to ${TEMP_DEB_PATH}"

# Verify download wasn't empty (basic check)
if [[ ! -s "${TEMP_DEB_PATH}" ]]; then
    log "Error: Downloaded KasmVNC file is empty. Download failed."
    rm -f "${TEMP_DEB_PATH}"
    exit 1
fi
log "Downloaded file size seems okay (not empty)."

log "Updating package lists (apt-get update)..."
# Redirect apt-get output to logs for debugging if needed, or let it print to stdout/stderr
if ! apt-get update; then
    log "Warning: apt-get update failed with exit code $?. Proceeding with installation attempt, but dependencies might be outdated."
fi
log "Package lists updated (or attempt finished)."

log "Installing KasmVNC Server package and dependencies..."
# Use -y to auto-confirm, --no-install-recommends to minimize extra packages
# Add DEBIAN_FRONTEND=noninteractive to prevent interactive prompts
export DEBIAN_FRONTEND=noninteractive
if ! apt-get install -y --no-install-recommends "${TEMP_DEB_PATH}"; then
    INSTALL_EXIT_CODE=$?
    log "Error: Initial apt-get install failed with exit code ${INSTALL_EXIT_CODE}. Attempting to fix broken dependencies..."
    # Attempt dependency fix if install failed
    if ! apt-get --fix-broken install -y; then
        log "Error: Failed to fix broken dependencies after KasmVNC install attempt (exit code $?)."
        rm -f "${TEMP_DEB_PATH}" # Clean up downloaded file
        exit 1
    fi
    # Retry install after fixing dependencies
    log "Retrying KasmVNC package installation after fixing dependencies..."
    if ! apt-get install -y --no-install-recommends "${TEMP_DEB_PATH}"; then
         log "Error: Failed to install KasmVNC package even after fixing dependencies (exit code $?)."
         rm -f "${TEMP_DEB_PATH}" # Clean up downloaded file
         exit 1
    fi
fi
log "KasmVNC package installed successfully."

log "Cleaning up downloaded KasmVNC deb file: ${TEMP_DEB_PATH}"
rm -f "${TEMP_DEB_PATH}"

# --- KasmVNC Configuration ---
log "Configuring KasmVNC..."

log "Creating KasmVNC configuration directory: ${KASM_CONFIG_DIR}"
mkdir -p "${KASM_CONFIG_DIR}"

# Check if Vast.ai SSL certs exist before writing config that references them
if [[ ! -f "${VAST_SSL_CERT}" ]]; then
    log "Warning: Vast.ai SSL certificate not found at ${VAST_SSL_CERT}. KasmVNC might generate/use self-signed certs."
fi
if [[ ! -f "${VAST_SSL_KEY}" ]]; then
    log "Warning: Vast.ai SSL private key not found at ${VAST_SSL_KEY}. KasmVNC might generate/use self-signed certs."
fi

log "Creating KasmVNC configuration file: ${KASM_CONFIG_FILE}"
# Use cat with heredoc for clarity
cat <<EOF > "${KASM_CONFIG_FILE}"
# KasmVNC configuration generated by provisioning script
logging:
  log_writer_name: "stdout" # Log to stdout/stderr for Docker/Supervisor capture

auth:
  type: "password"
  username: "${KASM_USER}"
  # WARNING: Password is set here. Use KASM_VNC_PASSWORD env var for production.
  password: "${KASM_PASSWORD}"

ssl:
  # Use Vast.ai provided certificates if available
  cert: "${VAST_SSL_CERT}"
  key: "${VAST_SSL_KEY}"

# Optional: Define session resource limits if needed
# session_limits:
#   cpu_limit: "4"
#   memory_limit: "8G"
EOF

log "Setting permissions for KasmVNC configuration file: ${KASM_CONFIG_FILE}"
chmod 644 "${KASM_CONFIG_FILE}"

# --- Supervisor Configuration for KasmVNC ---
log "Configuring Supervisor to manage KasmVNC..."

# Ensure supervisor conf directory exists
mkdir -p /etc/supervisor/conf.d/

# Create supervisor config file for KasmVNC
# Priority 950 ensures it starts after some base services if needed
log "Creating Supervisor configuration file: ${KASM_SUPERVISOR_CONF}"
cat <<EOF > "${KASM_SUPERVISOR_CONF}"
[program:kasmvnc]
command=/usr/bin/kasmvncserver --config ${KASM_CONFIG_FILE}
directory=/tmp
autostart=true
autorestart=true
startretries=5
startsecs=10
stopwaitsecs=60 ; Kasm might need longer to shut down sessions gracefully
user=root ; KasmVNC typically needs root for some operations
stdout_logfile=/dev/stdout ; Capture stdout to main docker log
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr ; Capture stderr to main docker log
stderr_logfile_maxbytes=0
priority=950
EOF
log "Supervisor configuration for KasmVNC created."

# --- Update Instance Portal ---
log "Adding KasmVNC link to Instance Portal UI..."

# Define the KasmVNC service details in JSON format for the portal tool
# Use variables defined at the top
KASM_PORTAL_JSON="{\"kasm\": {\"name\": \"${KASM_PORTAL_NAME}\", \"port\": ${KASM_INTERNAL_PORT}, \"proto\": \"${KASM_INTERNAL_PROTO}\"}}"

# Check if the portal config tool exists
if command -v vastai-set-portal-config &> /dev/null; then
    log "Found vastai-set-portal-config tool. Attempting to add Kasm config: ${KASM_PORTAL_JSON}"
    # Execute the command to add the KasmVNC entry
    if vastai-set-portal-config --add "${KASM_PORTAL_JSON}"; then
        log "Successfully added KasmVNC entry to Instance Portal configuration."
    else
        log "Warning: vastai-set-portal-config command finished with an error (exit code $?). Portal link might not be added correctly."
        # Decide if this is a fatal error? For now, just warn.
    fi
else
    log "Warning: vastai-set-portal-config command not found. Cannot dynamically update Instance Portal. KasmVNC link will be missing."
    # This is likely a significant issue if the portal is the main access method.
fi

# --- Final Steps ---
# Supervisor will pick up the new kasmvnc.conf file automatically
# when the main entrypoint script reloads or starts supervisor.
# No explicit 'supervisorctl update' or 'reload' needed *here*.

# Regarding the chmod error: Let's check if the expected script path exists
log "Checking if this script exists at expected path: /opt/provisioning/RunViso-provisioning.sh"
if [[ -f "/opt/provisioning/RunViso-provisioning.sh" ]]; then
    log "Script found at /opt/provisioning/RunViso-provisioning.sh."
else
    log "Error/Warning: This script was NOT found at /opt/provisioning/RunViso-provisioning.sh during execution. Path might be different?"
fi
# No other chmod commands are present in this script. The error "chmod: cannot access '/provisioning.sh'"
# seems unrelated to this script's content or originates from outside this script.

log "KasmVNC Provisioning Script Finished Successfully."

# Exit with 0 to indicate success to the entrypoint script
exit 0

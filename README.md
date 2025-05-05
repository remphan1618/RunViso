# Guide: Integrating KasmVNC on Vast.ai (remphan1618 Session)

**Current Status as of:** 2025-05-05 09:02:09 UTC
**User:** remphan1618

## 1. Goal

The primary objective is to install KasmVNC server within a custom Docker image deployed on Vast.ai and successfully integrate it with the Vast.ai Instance Portal UI. The desired outcome is a clickable "Kasm Desktop" link appearing alongside the default "Jupyter" link in the instance's web portal.

## 2. Key Components & Files

*   **`RunViso-Dockerfile`:** (Primary focus of current recommended approach) Defines the custom Docker image based on `vastai/base-image:cuda-12.4-auto`. It should contain all necessary software (including KasmVNC) and configurations.
*   **`RunViso-provisioning.sh`:** (Previously used, now likely unnecessary for Kasm) A Bash script, previously hosted remotely and executed at runtime via the `PROVISIONING_SCRIPT` environment variable. Used for installing KasmVNC *after* instance start, but encountered issues with portal integration timing.
*   **`RunViso-Setup.ipynb`:** A user-provided Jupyter notebook, not directly involved in the KasmVNC setup.
*   **`.github/workflows/build-runviso.yml`:** GitHub Actions workflow to build the `RunViso-Dockerfile` and push it to a container registry (e.g., Docker Hub).
*   **Vast.ai Template:** Configuration used to launch the instance, including the Docker image, launch mode, environment variables, and port mappings.
*   **`/opt/instance-tools/bin/entrypoint.sh`:** (Internal Vast.ai script) The main startup script in the base image. Manages environment setup, runs provisioning scripts, configures default services, generates portal config, and starts `supervisord`.
*   **`/etc/supervisor/conf.d/kasmvnc.conf`:** Configuration file required by `supervisord` to manage the KasmVNC process. Needs to be present in the final image.
*   **Instance Portal UI:** The web interface provided by Vast.ai for accessing services within the container.
*   **`/etc/portal.yaml`:** (Crucial configuration file) YAML file read by the `instance_portal` service to generate the UI links. Contains an `applications:` key.
*   **`/opt/instance-tools/bin/update-portal`:** (Internal Vast.ai script) Confirmed to be for updating the portal *software*, **not** for adding application links dynamically.

## 3. Troubleshooting Summary

*   **Initial Setup:** Remote provisioning script used for KasmVNC installation.
*   **Script Errors:** Resolved line ending issues (`\r: bad interpreter`).
*   **Download Issues:** Corrected invalid KasmVNC download URLs (S3, incorrect GitHub tags). Successfully downloaded and installed KasmVNC v1.3.4 using `https://github.com/kasmtech/KasmVNC/releases/download/v1.3.4/kasmvncserver_jammy_1.3.4_amd64.deb`. Supervisor config (`kasmvnc.conf`) was also created successfully.
*   **Portal Integration Failures:** Despite successful KasmVNC installation, the portal link failed to appear using various runtime methods within the provisioning script:
    *   Calling non-existent tools (`vastai-set-portal-config`).
    *   Modifying `/etc/portal.yaml` (overwritten/timing issues).
    *   Setting environment variables (`PORTAL_APP_*`, `PORTAL_CONFIG`).
*   **Hypothesis:** The main `entrypoint.sh` script likely finalizes/overwrites `/etc/portal.yaml` *after* the runtime provisioning script finishes, making runtime modifications unreliable for portal integration.

## 4. Recommended Approach: Build Everything into the Docker Image

To avoid runtime timing issues, the most reliable method is to install KasmVNC and create all necessary configuration files (including the final `/etc/portal.yaml` with both Jupyter and Kasm entries) directly within the `RunViso-Dockerfile`.

**Steps:**

1.  Modify `RunViso-Dockerfile` to perform all installation and configuration steps.
2.  Remove KasmVNC-related steps from `RunViso-provisioning.sh`.
3.  Update the Vast.ai template to remove the `PROVISIONING_SCRIPT` and `PORTAL_CONFIG` environment variables.
4.  Build the new image and deploy using the updated template.

## 5. Full Files for Recommended "Build into Image" Approach

### 5.1. `RunViso-Dockerfile`

```dockerfile name=RunViso-Dockerfile
# Use the Vast.ai base image with CUDA (auto-selected drivers recommended)
# Using a specific tag for reproducibility, update as needed.
FROM vastai/base-image:cuda-12.4-auto

# Metadata
LABEL maintainer="remphan1618"
LABEL description="Vast.ai environment with KasmVNC v1.3.4 built-in and portal configured"

# --- KasmVNC Installation Args ---
ARG KASM_VERSION="1.3.4"
ARG KASM_DEB_FILENAME="kasmvncserver_jammy_${KASM_VERSION}_amd64.deb"
ARG KASM_DOWNLOAD_URL="https://github.com/kasmtech/KasmVNC/releases/download/v${KASM_VERSION}/${KASM_DEB_FILENAME}"
ARG KASM_USER="kasm_user"
# Note: Default password is set here. Override via KASM_VNC_PASSWORD env var at runtime if needed (Kasm reads this).
ARG KASM_DEFAULT_PASSWORD="kasm_password"
ARG KASM_CONFIG_DIR="/etc/kasmvnc"
ARG KASM_CONFIG_FILE="${KASM_CONFIG_DIR}/kasmvnc.yaml"
ARG KASM_SUPERVISOR_CONF="/etc/supervisor/conf.d/kasmvnc.conf"
ARG PORTAL_CONFIG_FILE="/etc/portal.yaml"

# Set DEBIAN_FRONTEND to noninteractive for apt commands
ENV DEBIAN_FRONTEND=noninteractive

# --- Install Dependencies, Download & Install KasmVNC ---
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    jq \
    # Add any other dependencies KasmVNC might need explicitly if apt doesn't catch them
    # (Based on previous logs, many perl libs, x11 libs etc. were pulled - apt handles this)
    && \
    echo "Downloading KasmVNC from ${KASM_DOWNLOAD_URL}..." && \
    curl -fLsSo "/tmp/${KASM_DEB_FILENAME}" "${KASM_DOWNLOAD_URL}" && \
    echo "Installing KasmVNC..." && \
    apt-get install -y --no-install-recommends "/tmp/${KASM_DEB_FILENAME}" && \
    echo "Cleaning up..." && \
    rm -f "/tmp/${KASM_DEB_FILENAME}" && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# --- Create KasmVNC Configuration File ---
# Note: KasmVNC will use env vars like KASM_VNC_PASSWORD if set at runtime,
# overriding the password here if the env var is present.
# It will also auto-find Vast certs if present at runtime.
RUN mkdir -p "${KASM_CONFIG_DIR}" && \
    echo "# KasmVNC configuration generated during Docker build" > "${KASM_CONFIG_FILE}" && \
    echo "logging:" >> "${KASM_CONFIG_FILE}" && \
    echo "  log_writer_name: \"stdout\"" >> "${KASM_CONFIG_FILE}" && \
    echo "auth:" >> "${KASM_CONFIG_FILE}" && \
    echo "  type: \"password\"" >> "${KASM_CONFIG_FILE}" && \
    echo "  username: \"${KASM_USER}\"" >> "${KASM_CONFIG_FILE}" && \
    echo "  password: \"${KASM_DEFAULT_PASSWORD}\"" >> "${KASM_CONFIG_FILE}" && \
    echo "ssl:" >> "${KASM_CONFIG_FILE}" && \
    echo "  # Cert paths below are placeholders; Kasm/Vast entrypoint may override/provide these" >> "${KASM_CONFIG_FILE}" && \
    echo "  cert: \"/etc/ssl/certs/vast_ssl.crt\"" >> "${KASM_CONFIG_FILE}" && \
    echo "  key: \"/etc/ssl/private/vast_ssl.key\"" >> "${KASM_CONFIG_FILE}" && \
    chmod 644 "${KASM_CONFIG_FILE}"

# --- Create Supervisor Configuration for KasmVNC ---
RUN mkdir -p /etc/supervisor/conf.d/ && \
    echo "[program:kasmvnc]" > "${KASM_SUPERVISOR_CONF}" && \
    echo "command=/usr/bin/kasmvncserver --config ${KASM_CONFIG_FILE}" >> "${KASM_SUPERVISOR_CONF}" && \
    echo "directory=/tmp" >> "${KASM_SUPERVISOR_CONF}" && \
    echo "autostart=true" >> "${KASM_SUPERVISOR_CONF}" && \
    echo "autorestart=true" >> "${KASM_SUPERVISOR_CONF}" && \
    echo "startretries=5" >> "${KASM_SUPERVISOR_CONF}" && \
    echo "startsecs=10" >> "${KASM_SUPERVISOR_CONF}" && \
    echo "stopwaitsecs=60" >> "${KASM_SUPERVISOR_CONF}" && \
    echo "user=root" >> "${KASM_SUPERVISOR_CONF}" && \
    echo "stdout_logfile=/dev/stdout" >> "${KASM_SUPERVISOR_CONF}" && \
    echo "stdout_logfile_maxbytes=0" >> "${KASM_SUPERVISOR_CONF}" && \
    echo "stderr_logfile=/dev/stderr" >> "${KASM_SUPERVISOR_CONF}" && \
    echo "stderr_logfile_maxbytes=0" >> "${KASM_SUPERVISOR_CONF}" && \
    echo "priority=950" >> "${KASM_SUPERVISOR_CONF}"

# --- Create Portal Configuration File ---
# This includes BOTH Jupyter (assuming standard setup) and KasmVNC
# Ensure correct YAML indentation (two spaces)
RUN echo "# Portal configuration generated during Docker build" > "${PORTAL_CONFIG_FILE}" && \
    echo "applications:" >> "${PORTAL_CONFIG_FILE}" && \
    echo "  # Default Jupyter entry (adjust port/proto if different in your base)" >> "${PORTAL_CONFIG_FILE}" && \
    echo "  jupyter:" >> "${PORTAL_CONFIG_FILE}" && \
    echo "    name: Jupyter Lab" >> "${PORTAL_CONFIG_FILE}" && \
    echo "    port: 18080 # Internal Jupyter port" >> "${PORTAL_CONFIG_FILE}" && \
    echo "    proto: http" >> "${PORTAL_CONFIG_FILE}" && \
    echo "" >> "${PORTAL_CONFIG_FILE}" && \
    echo "  # KasmVNC entry" >> "${PORTAL_CONFIG_FILE}" && \
    echo "  kasm:" >> "${PORTAL_CONFIG_FILE}" && \
    echo "    name: Kasm Desktop" >> "${PORTAL_CONFIG_FILE}" && \
    echo "    port: 6901 # Internal KasmVNC port" >> "${PORTAL_CONFIG_FILE}" && \
    echo "    proto: https" >> "${PORTAL_CONFIG_FILE}" && \
    chmod 644 "${PORTAL_CONFIG_FILE}"

# --- Workspace Setup ---
WORKDIR /workspace
COPY RunViso-Setup.ipynb /workspace/RunViso-Setup.ipynb
RUN chmod -R 777 /workspace

# Expose ports (Informational)
EXPOSE 6901
EXPOSE 11111
EXPOSE 18080

# Inherit ENTRYPOINT and CMD from base image
# ENTRYPOINT ["/opt/instance-tools/bin/entrypoint.sh"]
# CMD []
```

### 5.2. `RunViso-provisioning.sh` (Simplified/Empty)

```bash name=RunViso-provisioning.sh
#!/bin/bash
# This script is no longer responsible for KasmVNC installation or portal config.
# Add any OTHER runtime setup steps here if needed.
echo "$(date '+%Y-%m-%d %H:%M:%S') [Provisioning]: No KasmVNC setup needed via provisioning script (handled in Dockerfile)."
exit 0
```

### 5.3. `RunViso-Setup.ipynb` (Unchanged)

```python name=RunViso-Setup.ipynb
# Basic setup notebook - Placeholder content
print("RunViso Setup Notebook Loaded")

# Add any initial setup commands, library installations, or checks needed here.
# For example:
# !pip install -q some-python-package
# !git clone https://github.com/some/repo.git

print("Environment ready.")
```

### 5.4. `.github/workflows/build-runviso.yml` (Unchanged)

```yaml name=.github/workflows/build-runviso.yml
name: Build RunViso Runtime Image

on:
  push:
    branches: [ main ] # Or your default branch
    # Trigger only if files relevant to the RunViso Docker image build change
    paths:
      - 'RunViso-Dockerfile'
      # - 'RunViso-provisioning.sh' # Keep if script still used for other things
      - 'RunViso-Setup.ipynb'
      - '.github/workflows/build-runviso.yml' # Also trigger if the workflow itself changes
  workflow_dispatch: # Allows manual triggering

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build and push RunViso image
        id: docker_build # Add an ID to reference outputs if needed
        uses: docker/build-push-action@v5
        with:
          context: . # Build context is the root
          file: ./RunViso-Dockerfile # Point to the Dockerfile in the root
          push: true
          tags: remphan1618/runviso:latest # Adjust tag if needed
          # Optional: Add build args if needed
          # build-args: |
          #   SOME_ARG=value
          # Optional: Enable Docker layer caching for faster builds
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

## 6. Vast.ai Template Changes for "Build into Image" Approach

1.  **Image:** Update to the tag of the newly built image (e.g., `remphan1618/runviso:latest`).
2.  **Launch Mode:** `Jupyter-python notebook + SSH` (No change).
3.  **On-start Script:** `entrypoint.sh` (No change - use the default).
4.  **Environment Variables:**
    *   `OPEN_BUTTON_PORT`: `1111` (Keep this).
    *   `PROVISIONING_SCRIPT`: **REMOVE THIS VARIABLE** or leave it blank.
    *   `PORTAL_CONFIG`: **REMOVE THIS VARIABLE** or leave it blank.
    *   *(Optional)* `KASM_VNC_PASSWORD`: `YourSecurePasswordHere` (Keep if needed, KasmVNC should read it).
5.  **Ports:** Ensure `6901`, `11111`, and `18080` (internal) are mapped correctly to host ports (e.g., `6901:6901/tcp`, `1111:11111/tcp`, `18080:18080/tcp`).

## 7. Expected `/etc/portal.yaml` Content

The `RunViso-Dockerfile` above should create `/etc/portal.yaml` with the following exact content:

```yaml name=expected_portal.yaml
# Portal configuration generated during Docker build
applications:
  # Default Jupyter entry (adjust port/proto if different in your base)
  jupyter:
    name: Jupyter Lab
    port: 18080 # Internal Jupyter port
    proto: http

  # KasmVNC entry
  kasm:
    name: Kasm Desktop
    port: 6901 # Internal KasmVNC port
    proto: https
```

---

This guide provides a clear record of the process and the rationale for the recommended "Build into Image" approach, which should resolve the portal integration issues by eliminating runtime timing conflicts.
#!/bin/bash
# Set default variables
export HOME=/root
export USER=root
export DISPLAY=:1
export LANG=en_US.UTF-8

# Create necessary directories
mkdir -p ~/.vnc

# Create an Xauthority file if it doesn't exist
touch ~/.Xauthority

# Create password file if it doesn't exist
# Use a default password if KASM_VNC_PASSWORD env var is not set
if [ ! -f ~/.vnc/passwd ]; then
  echo "${KASM_VNC_PASSWORD:-kasm_password}" | vncpasswd -f > ~/.vnc/passwd
  chmod 600 ~/.vnc/passwd
fi

# Create symlinks for certificates if they don't exist
# This uses the snakeoil certs provided by the base image
if [ ! -f /etc/ssl/certs/vast_ssl.crt ]; then
  ln -sf /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/ssl/certs/vast_ssl.crt
fi
if [ ! -f /etc/ssl/private/vast_ssl.key ]; then
  ln -sf /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/private/vast_ssl.key
fi

# Start a virtual X server (Xvfb) if not already running
# Clean up stale locks first
pkill -f "Xvfb :1" || true
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 || true
Xvfb :1 -screen 0 1920x1080x24 &
sleep 2

# Start a lightweight window manager (xfce4)
if ! pgrep -x "xfce4-session" > /dev/null; then
    dbus-launch xfce4-session &
    sleep 2
fi

# Now launch KasmVNC with the specified options
# Use tee to capture stdout/stderr to a log file
exec /usr/bin/kasmvncserver \
  --desktop "Kasm Desktop" \
  --rfbport 6901 \
  --websocketPort auto \
  --cert /etc/ssl/certs/vast_ssl.crt \
  --key /etc/ssl/private/vast_ssl.key \
  --PasswordFile /root/.vnc/passwd \
  --SecurityTypes None \
  --interface localhost \
  2>&1 | tee -a /var/log/portal/kasmvnc.log

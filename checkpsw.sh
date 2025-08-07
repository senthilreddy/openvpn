#!/bin/bash

PASSFILE="/etc/openvpn/auth/users.txt"
LOGFILE="/var/log/openvpn-auth.log"

# Username and password come from OpenVPN via env
user="$username"
pass="$password"

echo "$(date) - Attempt: user='$user' pass='$pass'" >> "$LOGFILE"

# Check empty
if [ -z "$user" ] || [ -z "$pass" ]; then
  echo "$(date) - Auth failed: empty username or password" >> "$LOGFILE"
  exit 1
fi

# Read matching line (supports space OR colon separator)
line=$(grep -E "^$user[: ]" "$PASSFILE" | head -n1)

if [ -z "$line" ]; then
  echo "$(date) - Auth failed: user not found in $PASSFILE" >> "$LOGFILE"
  exit 1
fi

# Extract password from line
stored_pass=$(echo "$line" | awk -F'[: ]' '{print $2}')

if [ "$stored_pass" = "$pass" ]; then
  echo "$(date) - Auth success for $user" >> "$LOGFILE"
  exit 0
else
  echo "$(date) - Auth failed: wrong password for $user" >> "$LOGFILE"
  exit 1
fi
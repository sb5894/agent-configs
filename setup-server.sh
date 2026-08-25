#!/bin/bash
# Bootstraps a fresh Oracle Cloud Ubuntu instance with everything needed
# to run Hermes Agent + Claude Code CLI, based on lessons learned setting
# up my-agent-server (AMD Micro) on 2026-08-25.
#
# Usage on a brand new instance:
#   curl -fsSL https://raw.githubusercontent.com/sb5894/agent-configs/main/setup-server.sh | bash
#
# This script only handles the non-interactive parts. It stops and prints
# instructions for the steps that need a human (API keys, Discord token,
# Claude login).

set -e

echo "=== 1) Swap space (2GB) ==="
if [ -f /swapfile ]; then
  echo "swapfile already exists, skipping"
else
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi
free -h

echo "=== 2) Firewall (ufw) ==="
sudo apt-get update -y
sudo apt-get install -y ufw
sudo ufw allow OpenSSH
sudo ufw --force enable
sudo ufw status

echo "=== 3) Hermes Agent install ==="
if command -v hermes >/dev/null 2>&1; then
  echo "hermes already installed, skipping"
else
  # Download first, then run (piping curl|bash breaks interactive prompts
  # inside the installer on low-memory instances)
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh -o /tmp/hermes-install.sh
  bash /tmp/hermes-install.sh
  source ~/.bashrc
fi

echo "=== 4) Claude Code CLI install ==="
if command -v claude >/dev/null 2>&1; then
  echo "claude already installed, skipping"
else
  curl -fsSL https://claude.ai/install.sh | bash
fi

cat << 'EOF'

=========================================================
Automated part done. Remaining steps need you (interactive):

1. Model + provider setup for Hermes:
     hermes setup
   -> pick "8. Enter custom model name", enter your model (e.g. openai/gpt-4o)
   -> pick OpenAI provider "2. OpenAI API", paste your API key

2. Discord gateway:
     hermes gateway setup
   -> paste your Discord bot token
   -> set DISCORD_ALLOWED_USERS to your Discord user ID
   -> when asked "Install as background service?" -> Y
   -> when asked "Start automatically on boot?" -> Y

   IMPORTANT: if the gateway crash-loops with "Gateway already running
   (PID xxxx)", that PID is a stale lock from a killed process. Fix:
     ps aux | grep hermes        # find the stale PID
     sudo kill -9 <stale PID>
     sudo systemctl restart hermes-gateway

   If systemctl status shows a "Gateway already running" restart loop even
   after that, add --replace to the ExecStart line:
     sudo sed -i 's/gateway run$/gateway run --replace/' \
       /etc/systemd/system/hermes-gateway.service
     sudo systemctl daemon-reload
     sudo systemctl restart hermes-gateway

3. Claude Code login:
     mkdir -p ~/workspace && cd ~/workspace
     claude
   -> follow the login link, then "1. Yes, I trust this folder"

4. Idle-reclaim warning: Oracle reclaims Always Free compute instances
   idle for 7 straight days (95th percentile CPU < 20%). Once Hermes
   gateway is running as a systemd service (step 2), this instance will
   no longer look idle, so no action needed beyond that.
=========================================================
EOF

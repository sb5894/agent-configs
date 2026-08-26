#!/bin/bash
# Bootstraps a fresh Oracle Cloud Ubuntu instance with everything needed
# to run Hermes Agent + Claude Code CLI, based on lessons learned setting
# up my-agent-server (AMD Micro) on 2026-08-25.
#
# Usage on a brand new instance -- download first, then run. Do NOT pipe this
# into bash: the installers it calls read from stdin for their prompts, and a
# pipe feeds them the rest of this script instead of your keystrokes.
#
#   curl -fsSL https://raw.githubusercontent.com/sb5894/agent-configs/main/setup-server.sh -o setup-server.sh
#   bash setup-server.sh
#
# Optional:
#   ENABLE_UFW=1 bash setup-server.sh    # add a host firewall (see step 2)
#
# This script only handles the non-interactive parts. It stops and prints
# instructions for the steps that need a human (API keys, Discord token,
# Claude login).

set -e

if [ ! -t 0 ]; then
  cat >&2 <<'ERR'
ERROR: stdin is not a terminal.

You probably ran this as `curl ... | bash`. The Hermes installer prompts for
input, and a pipe hands it this script's own text instead. Download it first:

  curl -fsSL <url-of-this-script> -o setup-server.sh
  bash setup-server.sh
ERR
  exit 1
fi

echo "=== 1) Swap space (2GB) ==="
# The 1GB Always Free shapes will OOM-kill sshd under load, which looks like
# a network outage from the outside. Swap first, before anything heavy runs.
if swapon --show | grep -q '^/swapfile'; then
  echo "/swapfile already active, skipping"
else
  if [ ! -f /swapfile ]; then
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
  fi
  sudo swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi
free -h

echo "=== 2) Host firewall (ufw) ==="
# Oracle already gives you two layers of filtering:
#   1. the VCN Security List / NSG, configured in the web console
#   2. iptables rules baked into the Ubuntu image (/etc/iptables/rules.v4),
#      which already reject everything except SSH
# A third layer is one more place to forget about, and `ufw enable` with only
# OpenSSH allowed has locked people out of services they had just opened. So
# it is opt-in here rather than on by default.
if [ "${ENABLE_UFW:-0}" = "1" ]; then
  sudo apt-get update -y
  sudo apt-get install -y ufw
  sudo ufw allow OpenSSH
  # Add every other port you serve HERE, before enabling. For example:
  #   sudo ufw allow 443/tcp
  sudo ufw --force enable
  sudo ufw status verbose
else
  echo "skipped -- set ENABLE_UFW=1 to turn it on."
  echo "Relying on the VCN Security List plus the image's default iptables rules."
fi

echo "=== 3) Hermes Agent install ==="
if command -v hermes >/dev/null 2>&1; then
  echo "hermes already installed, skipping"
else
  # Download first, then run. The installer prompts interactively, so it needs
  # a real terminal -- see the stdin check at the top of this script.
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh -o /tmp/hermes-install.sh
  bash /tmp/hermes-install.sh
  # shellcheck disable=SC1090
  source ~/.bashrc || true
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

0. Set a password for the ubuntu user, if you have not already:
     sudo passwd ubuntu
   Oracle images ship with no password, so the browser serial console
   (Instance -> Console connection) cannot log you in without one. That
   console is the only way back in when SSH is unreachable. Do this now,
   not after you need it.

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

   Run long sessions inside tmux so a dropped connection does not kill them:
     tmux new -s main        # detach with Ctrl+b then d
     tmux attach -t main     # come back later

4. Idle-reclaim warning: Oracle reclaims Always Free compute instances
   idle for 7 straight days (95th percentile CPU < 20%). Once Hermes
   gateway is running as a systemd service (step 2), this instance will
   no longer look idle, so no action needed beyond that.

Can't reach the instance over SSH at all? See TROUBLESHOOTING.md.
=========================================================
EOF

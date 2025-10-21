#!/bin/bash
# =====================================================================
# Title: deploy.sh
# Purpose: Automate setup, deployment, and configuration of a Dockerized app
# Author: DevOps Intern (HNG Project)
# Description:
#   This script automates the full CI/CD workflow for a Dockerized
#   application from GitHub to a remote Linux server, including:
#   - Repository cloning or update
#   - Docker & Nginx setup
#   - Container deployment
#   - Nginx reverse proxy configuration
#   - Logging, error handling, and cleanup
# =====================================================================

# Exit on any error
set -euo pipefail

# Log file
LOGFILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# ------------- Helper Functions -------------

log() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

error_exit() {
  log "❌ ERROR: $1"
  exit 1
}

trap 'error_exit "Unexpected error on line $LINENO"' ERR

# ------------- Parse Arguments -------------

if [[ "${1:-}" == "--cleanup" ]]; then
  CLEANUP=true
else
  CLEANUP=false
fi

# ------------- Step 1: Collect Parameters -------------

log "🧠 Collecting deployment parameters..."

read -p "Enter Git repository URL: " GIT_URL
read -p "Enter your Personal Access Token (PAT): " PAT
read -p "Enter branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}

read -p "Enter remote server username: " SSH_USER
read -p "Enter remote server IP address: " SERVER_IP
read -p "Enter SSH key path (e.g., ~/.ssh/id_rsa): " SSH_KEY
read -p "Enter app internal container port (e.g., 3000): " APP_PORT

[[ -z "$GIT_URL" || -z "$PAT" || -z "$SSH_USER" || -z "$SERVER_IP" || -z "$SSH_KEY" || -z "$APP_PORT" ]] && error_exit "Missing one or more required inputs."

# ------------- Step 2: Clone or Update Repository -------------

REPO_NAME=$(basename "$GIT_URL" .git)

log "📦 Cloning or updating repository..."

if [ -d "$REPO_NAME" ]; then
  log "📁 Repo exists locally. Pulling latest changes..."
  cd "$REPO_NAME" || error_exit "Failed to enter repo directory."
  git pull origin "$BRANCH" || error_exit "Git pull failed."
else
  git clone -b "$BRANCH" "https://${PAT}@${GIT_URL#https://}" || error_exit "Git clone failed."
  cd "$REPO_NAME" || error_exit "Failed to enter cloned directory."
fi

# ------------- Step 3: Validate Docker Configuration -------------

if [ -f "Dockerfile" ]; then
  log "✅ Dockerfile found."
elif [ -f "docker-compose.yml" ]; then
  log "✅ docker-compose.yml found."
else
  error_exit "No Dockerfile or docker-compose.yml found in repo."
fi

# ------------- Step 4: Test SSH Connection -------------

log "🔐 Testing SSH connectivity..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$SERVER_IP" "echo 'SSH connection successful.'" || error_exit "SSH connection failed."

# ------------- Step 5: Prepare Remote Environment -------------

log "🛠️ Preparing remote server environment..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<EOF
  set -e
  echo "Updating system..." && sudo apt update -y
  echo "Installing Docker..." && sudo apt install -y docker.io
  echo "Installing Docker Compose..." && sudo apt install -y docker-compose
  echo "Installing Nginx..." && sudo apt install -y nginx
  sudo usermod -aG docker $SSH_USER || true
  sudo systemctl enable docker nginx
  sudo systemctl start docker nginx
  echo "✅ Remote environment ready."
EOF

# ------------- Step 6: Cleanup (if requested) -------------

if [ "$CLEANUP" = true ]; then
  log "🧹 Cleanup flag detected. Removing previous deployment..."
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<EOF
    sudo docker stop hng || true
    sudo docker rm hng || true
    sudo docker system prune -af || true
    sudo rm -rf ~/app /etc/nginx/sites-available/hng.conf /etc/nginx/sites-enabled/hng.conf
    sudo systemctl reload nginx || true
  EOF
  log "✅ Cleanup complete. Exiting."
  exit 0
fi

# ------------- Step 7: Deploy Dockerized Application -------------

log "🚀 Deploying Dockerized app..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "mkdir -p ~/app"

rsync -avz -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" . "$SSH_USER@$SERVER_IP:~/app" >> "$LOGFILE" 2>&1

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<EOF
  set -e
  cd ~/app
  if [ -f "docker-compose.yml" ]; then
    sudo docker-compose down || true
    sudo docker-compose up -d --build
  else
    sudo docker stop hng || true
    sudo docker rm hng || true
    sudo docker build -t hng .
    sudo docker run -d -p ${APP_PORT}:${APP_PORT} --name hng hng
  fi
EOF

# ------------- Step 8: Configure Nginx Reverse Proxy -------------

log "🌐 Configuring Nginx reverse proxy..."

NGINX_CONF="
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "echo \"$NGINX_CONF\" | sudo tee /etc/nginx/sites-available/hng.conf"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "sudo ln -sf /etc/nginx/sites-available/hng.conf /etc/nginx/sites-enabled/hng.conf"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "sudo nginx -t && sudo systemctl reload nginx"

# ------------- Step 9: Validate Deployment -------------

log "🧪 Validating deployment..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<EOF
  sudo systemctl status docker --no-pager
  sudo docker ps
  curl -I http://localhost || echo "App may not be responding yet."
EOF

log "🎉 Deployment complete! Access your app at: http://$SERVER_IP"

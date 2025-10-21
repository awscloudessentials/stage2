#!/bin/bash

# ==============================================
# Simple Automated Docker App Deployment Script
# ==============================================
# Author: New DevOps Intern
# Purpose: Automate setup and deployment of a Dockerized app to a remote server
# ==============================================

LOGFILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# -------- Logging Helper --------
log() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

error_exit() {
  log "❌ ERROR: $1"
  exit 1
}

# -------- Step 1: Collect Parameters --------
log "🧠 Collecting deployment parameters..."

read -p "Enter Git repository URL: " GIT_URL
read -p "Enter your Personal Access Token (PAT): " PAT
read -p "Enter branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}

read -p "Enter remote server username: " SSH_USER
read -p "Enter remote server IP address: " SERVER_IP
read -p "Enter SSH key path (e.g., ~/.ssh/id_rsa): " SSH_KEY
read -p "Enter app internal container port (e.g., 3000): " APP_PORT

# -------- Validate Inputs --------
[[ -z "$GIT_URL" || -z "$PAT" || -z "$SSH_USER" || -z "$SERVER_IP" || -z "$SSH_KEY" || -z "$APP_PORT" ]] && error_exit "Missing one or more required inputs."

# -------- Step 2: Clone Repository --------
log "📦 Cloning repository..."

REPO_NAME=$(basename "$GIT_URL" .git)

if [ -d "$REPO_NAME" ]; then
  log "📁 Repo exists locally. Pulling latest changes..."
  cd "$REPO_NAME" || error_exit "Failed to enter repo directory."
  git pull origin "$BRANCH" || error_exit "Git pull failed."
else
  git clone -b "$BRANCH" "https://${PAT}@${GIT_URL#https://}" || error_exit "Git clone failed."
  cd "$REPO_NAME" || error_exit "Failed to enter cloned directory."
fi

# -------- Step 3: Validate Docker Setup --------
if [ -f "Dockerfile" ]; then
  log "✅ Dockerfile found."
elif [ -f "docker-compose.yml" ]; then
  log "✅ docker-compose.yml found."
else
  error_exit "No Dockerfile or docker-compose.yml found in repo."
fi

# -------- Step 4: Test SSH Connection --------
log "🔐 Testing SSH connectivity..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$SERVER_IP" "echo 'Connected!'" || error_exit "SSH connection failed."

# -------- Step 5: Prepare Remote Environment --------
log "🛠️ Preparing remote server environment..."

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
  set -e
  echo "Updating system..." && sudo apt update -y
  echo "Installing Docker..." && sudo apt install -y docker.io
  echo "Installing Docker Compose..." && sudo apt install -y docker-compose
  echo "Installing Nginx..." && sudo apt install -y nginx
  sudo systemctl enable docker nginx
  sudo systemctl start docker nginx
  echo "✅ Remote environment ready."
EOF

# -------- Step 6: Deploy Dockerized App --------
log "🚀 Deploying Dockerized app..."

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "mkdir -p ~/app"

rsync -avz -e "ssh -i $SSH_KEY" . "$SSH_USER@$SERVER_IP:~/app" >> "$LOGFILE" 2>&1

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
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

# -------- Step 7: Configure Nginx as Reverse Proxy --------
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

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "echo \"$NGINX_CONF\" | sudo tee /etc/nginx/sites-available/hng.conf"
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "sudo ln -sf /etc/nginx/sites-available/hng.conf /etc/nginx/sites-enabled/hng.conf"
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "sudo nginx -t && sudo systemctl reload nginx"

# -------- Step 8: Validate Deployment --------
log "🧪 Validating deployment..."

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
  sudo systemctl status docker --no-pager
  sudo docker ps
  curl -I http://localhost || echo "App may not be responding yet."
EOF

log "🎉 Deployment complete! Check your app via http://$SERVER_IP"

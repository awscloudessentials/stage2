# 🚀 Dockerized App Deployment Script

## 📖 Overview
This project automates the **setup, deployment, and configuration** of a Dockerized application on a remote Linux server.

It includes:
- Automatic Docker + Nginx installation
- GitHub repo cloning via Personal Access Token (PAT)
- Containerized app deployment
- Reverse proxy configuration
- Logging and cleanup options

---

## ⚙️ Requirements
- Linux/macOS system with `bash`, `git`, and `rsync`
- Remote server (Ubuntu recommended)
- SSH key-based access to the remote server
- Dockerized project (`Dockerfile` or `docker-compose.yml`)
- GitHub Personal Access Token (PAT)

---

## 🧩 Usage

1️⃣ **Make the script executable**
```bash
chmod +x deploy.sh

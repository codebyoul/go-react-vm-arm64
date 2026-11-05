#!/usr/bin/env bash
# init-virtualbox-vm.sh
# Minimal Debian (arm64) VM in VirtualBox on macOS Apple Silicon, fully provisioned by cloud-init:
#   - sudo user with password + SSH
#   - Go (backend) + Node/npm + React/Vite (frontend) + build tools
#   - Hello-world app (Go serves API + built React) running as a systemd service
#   - Mac ports forwarded to the VM, end-to-end test from the Mac
#
# Usage:   ./init-virtualbox-vm.sh [vm-name] [--force]
# Debug:   DEBUG=1 ./init-virtualbox-vm.sh [vm-name] --force
# Variant: IMAGE_VARIANT=generic ./init-virtualbox-vm.sh ...   (bigger image, more drivers)
# Logs:    ~/.cache/vbox-debian/logs/<vm>-<timestamp>.log (+ screenshots)

set -Eeuo pipefail

############################ EDIT HERE ############################
VM_USER="${VM_USER:-admin}"                    # sudo user (SSH enabled, password login)
VM_PASSWORD="${VM_PASSWORD:-admin}"     # its password (avoid ' characters)
RAM_MB="${RAM_MB:-8192}"
CPUS="${CPUS:-3}"
DISK_MB="${DISK_MB:-51200}"                    # 50 GB
SSH_PORT="${SSH_PORT:-2222}"                   # Mac port -> VM 22
HTTP_PORT="${HTTP_PORT:-8080}"                 # Mac port -> VM 8080 (Go backend + built React)
DEV_PORT="${DEV_PORT:-5173}"                   # Mac port -> VM 5173 (Vite dev server)
BIND_IP="${BIND_IP:-127.0.0.1}"                # 127.0.0.1 = only your Mac | empty = whole LAN
TIMEZONE="${TIMEZONE:-Europe/Paris}"
PACKAGES="${PACKAGES:-sudo curl wget git vim-tiny htop ca-certificates openssh-server unattended-upgrades golang-go nodejs npm build-essential make jq unzip rsync}"
DEBIAN_RELEASE="${DEBIAN_RELEASE:-trixie}"
DEBIAN_VERSION="${DEBIAN_VERSION:-13}"
IMAGE_VARIANT="${IMAGE_VARIANT:-genericcloud}" # genericcloud (smallest, virtio only) | generic
SSH_WAIT_SECONDS="${SSH_WAIT_SECONDS:-420}"
CLOUDINIT_WAIT_SECONDS="${CLOUDINIT_WAIT_SECONDS:-1800}"
###################################################################

VM_NAME="debian-server"; FORCE=0
for a in "$@"; do
  case "$a" in --force) FORCE=1 ;; *) VM_NAME="$a" ;; esac
done

CACHE_DIR="$HOME/.cache/vbox-debian"
LOG_DIR="$CACHE_DIR/logs"
VM_BASE="$HOME/VirtualBox VMs"
VM_DIR="$VM_BASE/$VM_NAME"
SSH_KEY="$HOME/.ssh/id_ed25519_vbox"
IMG_URL="https://cloud.debian.org/images/cloud/${DEBIAN_RELEASE}/latest/debian-${DEBIAN_VERSION}-${IMAGE_VARIANT}-arm64.tar.xz"
TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/${VM_NAME}-${TS}.log"
DIAG_READY=""

# ---------- Logging: screen AND file ----------
exec > >(tee -a "$LOGFILE") 2>&1
[[ "${DEBUG:-0}" == "1" ]] && { export PS4='+ [${LINENO}] '; set -x; }

now()  { date '+%H:%M:%S'; }
log()  { printf '\n\033[1;34m[%s] ==>\033[0m %s\n' "$(now)" "$*"; }
info() { printf '[%s]     %s\n' "$(now)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$(now)" "$*"; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(now)" "$*" >&2; diagnostics; exit 1; }

vm_state() { VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null | awk -F'"' '/^VMState=/{print $2}'; }
vm_ssh()   { ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "$@"; }

screenshot() {
  local f="$LOG_DIR/${VM_NAME}-${TS}-$1.png"
  VBoxManage controlvm "$VM_NAME" screenshotpng "$f" >/dev/null 2>&1 && info "screenshot: $f"
}

diagnostics() {
  set +e +x +u
  echo; echo "################ DIAGNOSTICS ################"
  echo "Log file:  $LOGFILE"
  echo "VBox ver:  $(VBoxManage --version 2>&1)"
  echo "VM state:  $(vm_state)"
  echo "--- VM config ---"
  VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null \
    | grep -E '^(memory|cpus|firmware|graphicscontroller|vram|nic1|nictype1|cableconnected1|Forwarding|uart)'
  echo "--- Host ports ---"
  for p in "$SSH_PORT" "$HTTP_PORT" "$DEV_PORT"; do nc -vz -w 3 127.0.0.1 "$p" 2>&1; done
  if [[ -n "$DIAG_READY" ]]; then
    echo "--- SSH verbose attempt ---"
    ssh -v "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" true 2>&1 | tail -n 15
    echo "--- Inside VM: cloud-init + app setup ---"
    vm_ssh "sudo cloud-init status --long; echo; cat /var/lib/app-setup.status 2>/dev/null; echo; \
            sudo tail -n 60 /var/log/app-setup.log 2>/dev/null; echo; \
            sudo systemctl status app-backend --no-pager 2>&1 | tail -n 15; echo; \
            sudo journalctl -u app-backend --no-pager -n 20 2>&1; echo; \
            ip -4 -br a; systemctl --failed --no-legend; \
            sudo tail -n 30 /var/log/cloud-init-output.log" 2>&1
  fi
  screenshot "diagnostics"
  echo "--- VBox.log: errors ---"
  grep -iE 'VERR_|error|fail|abort' "$VM_DIR/Logs/VBox.log" 2>/dev/null | tail -n 25
  cat <<EOF

---- Things to try ----
  Screenshots:           open "$LOG_DIR"      or   VBoxManage startvm $VM_NAME --type gui
  Inside the VM:         ssh ${VM_USER}@127.0.0.1 -p ${SSH_PORT}
     app setup log:      sudo cat /var/log/app-setup.log
     cloud-init log:     sudo cat /var/log/cloud-init-output.log
     backend log:        sudo journalctl -u app-backend -f
  Bigger image:          IMAGE_VARIANT=generic $0 $VM_NAME --force
  Shell trace:           DEBUG=1 $0 $VM_NAME --force
#############################################
EOF
}

on_error() { local c=$? l=$1; printf '\033[1;31m[%s] Script failed at line %s (exit %s): %s\033[0m\n' "$(now)" "$l" "$c" "${BASH_COMMAND}"; }
trap 'on_error $LINENO' ERR

WORK="$(mktemp -d)"
cleanup() { hdiutil detach "$WORK/mnt" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

# ---------- Checks ----------
log "Environment checks"
[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon required."
command -v VBoxManage >/dev/null || die "VBoxManage not found."
info "macOS $(sw_vers -productVersion), VirtualBox $(VBoxManage --version)"
info "Log file: $LOGFILE"
info "Image:    $IMG_URL"

if VBoxManage list vms | grep -q "\"$VM_NAME\""; then
  if [[ $FORCE -eq 1 ]]; then
    log "Removing existing VM '$VM_NAME'"
    VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
    sleep 2
    VBoxManage unregistervm "$VM_NAME" --delete
  else
    die "VM '$VM_NAME' exists. Re-run with: $0 $VM_NAME --force"
  fi
fi
rm -rf "$VM_DIR"

for v in SSH_PORT HTTP_PORT DEV_PORT; do
  while nc -z 127.0.0.1 "${!v}" 2>/dev/null; do warn "Mac port ${!v} busy ($v)"; printf -v "$v" '%s' "$(( ${!v} + 1 ))"; done
done
info "Mac ports: ssh=$SSH_PORT http=$HTTP_PORT dev=$DEV_PORT (bind: ${BIND_IP:-all interfaces})"

SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5 -o IdentitiesOnly=yes -o BatchMode=yes)
DIAG_READY=1

# ---------- SSH key (used by this script to check readiness) ----------
if [[ ! -f "$SSH_KEY" ]]; then
  log "Generating SSH key"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N "" -C "vbox-$VM_NAME" -f "$SSH_KEY" >/dev/null
fi
PUBKEY="$(cat "${SSH_KEY}.pub")"

# ---------- Download image ----------
TARBALL="$CACHE_DIR/$(basename "$IMG_URL")"
if [[ ! -f "$TARBALL" ]]; then
  log "Downloading image"
  curl -fL --progress-bar -o "$TARBALL.part" "$IMG_URL" || die "Download failed: $IMG_URL"
  mv "$TARBALL.part" "$TARBALL"
else
  info "Using cached image: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
fi

log "Extracting image"
tar -xJf "$TARBALL" -C "$WORK"
RAW="$WORK/disk.raw"
[[ -f "$RAW" ]] || die "disk.raw not found in tarball."

mkdir -p "$VM_DIR"
DISK="$VM_DIR/${VM_NAME}.vdi"
SEED="$VM_DIR/${VM_NAME}-seed.vdi"

log "Converting to VDI and resizing to ${DISK_MB} MB"
VBoxManage convertfromraw "$RAW" "$DISK" --format VDI
VBoxManage modifymedium disk "$DISK" --resize "$DISK_MB"

# =====================================================================
#  APP PAYLOAD (Go backend + React frontend + setup script), shipped in cloud-init
# =====================================================================
log "Preparing application payload (Go + React hello world)"
PAYLOAD="$WORK/payload"
mkdir -p "$PAYLOAD/app/backend" "$PAYLOAD/app/frontend/src"

# ---- Go backend ----
cat > "$PAYLOAD/app/backend/go.mod" <<'EOF'
module app

go 1.22
EOF

cat > "$PAYLOAD/app/backend/main.go" <<'EOF'
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}

// Serves built React files; unknown paths fall back to index.html (client-side routing).
func spa(dir string) http.Handler {
	fs := http.FileServer(http.Dir(dir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := filepath.Join(dir, filepath.Clean("/"+r.URL.Path))
		if _, err := os.Stat(p); err != nil {
			http.ServeFile(w, r, filepath.Join(dir, "index.html"))
			return
		}
		fs.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func main() {
	port := env("PORT", "8080")
	static := env("STATIC_DIR", "../frontend/dist")

	mux := http.NewServeMux()
	mux.HandleFunc("/api/hello", func(w http.ResponseWriter, r *http.Request) {
		host, _ := os.Hostname()
		writeJSON(w, 200, map[string]string{
			"message":    "Hello World from the Go backend!",
			"go_version": runtime.Version(),
			"hostname":   host,
			"time":       time.Now().Format(time.RFC3339),
		})
	})
	mux.HandleFunc("/api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 404, map[string]string{"error": "not found"})
	})
	mux.Handle("/", spa(static))

	log.Printf("listening on :%s, serving static files from %s", port, static)
	log.Fatal(http.ListenAndServe(":"+port, logging(mux)))
}
EOF

# ---- React (Vite) frontend ----
cat > "$PAYLOAD/app/frontend/package.json" <<'EOF'
{
  "name": "frontend",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite --host 0.0.0.0 --port 5173",
    "build": "vite build",
    "preview": "vite preview --host 0.0.0.0 --port 4173"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.4",
    "vite": "^6.0.0"
  }
}
EOF

cat > "$PAYLOAD/app/frontend/vite.config.js" <<'EOF'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// In dev mode, /api/* is proxied to the Go backend on :8080
export default defineConfig({
  plugins: [react()],
  server: { host: true, port: 5173, proxy: { '/api': 'http://127.0.0.1:8080' } },
})
EOF

cat > "$PAYLOAD/app/frontend/index.html" <<'EOF'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Go + React Hello World</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

cat > "$PAYLOAD/app/frontend/src/main.jsx" <<'EOF'
import React from 'react'
import { createRoot } from 'react-dom/client'
import App from './App.jsx'

createRoot(document.getElementById('root')).render(<App />)
EOF

cat > "$PAYLOAD/app/frontend/src/App.jsx" <<'EOF'
import { useEffect, useState } from 'react'

export default function App() {
  const [data, setData] = useState(null)
  const [error, setError] = useState(null)

  useEffect(() => {
    fetch('/api/hello')
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error('HTTP ' + r.status))))
      .then(setData)
      .catch((e) => setError(e.message))
  }, [])

  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', maxWidth: 640, margin: '4rem auto', padding: '0 1rem' }}>
      <h1>Hello World from React</h1>
      {data && (
        <div style={{ background: '#e6ffed', border: '1px solid #34d058', borderRadius: 8, padding: '1rem' }}>
          <strong>Setup successful: React talks to Go.</strong>
          <pre>{JSON.stringify(data, null, 2)}</pre>
        </div>
      )}
      {error && (
        <div style={{ background: '#ffeef0', border: '1px solid #d73a49', borderRadius: 8, padding: '1rem' }}>
          Backend not reachable: {error}
        </div>
      )}
      {!data && !error && <p>Calling /api/hello ...</p>}
    </main>
  )
}
EOF

# ---- Helper files ----
cat > "$PAYLOAD/app/.gitignore" <<'EOF'
node_modules/
frontend/dist/
bin/
EOF

cat > "$PAYLOAD/app/deploy.sh" <<'EOF'
#!/usr/bin/env bash
# Rebuild everything and restart the service. Run from anywhere inside the VM: ~/app/deploy.sh
set -euo pipefail
cd "$(dirname "$0")"
echo "==> Building Go backend";   (cd backend && go mod tidy && go build -o ../bin/server .)
echo "==> Building React frontend"; (cd frontend && npm install --no-audit --no-fund && npm run build)
echo "==> Restarting service";    sudo systemctl restart app-backend
sleep 1
curl -fsS http://127.0.0.1:8080/api/health && echo "  -> deployed OK"
EOF

cat > "$PAYLOAD/app/LLM_PROMPT.md" <<'EOF'
# Project rules (read first)

You work inside a Debian VM. Project root: `~/app` (git repo). Stack: **Go backend + React (Vite) frontend**.

## Where code goes
- `backend/` : Go (stdlib `net/http`, module `app`). Entry: `backend/main.go`. All API routes live under `/api/*`.
- `frontend/src/` : React code. Call the API with relative URLs only: `fetch('/api/...')`. Never hardcode host or port.
- Go serves the built React files from `frontend/dist`, so one process serves everything on port **8080**.

## How to deploy (always do this after any change)
    ~/app/deploy.sh
It runs `go build`, `npm install && npm run build`, restarts the `app-backend` systemd service, and checks `/api/health`.

## How to test
- Inside the VM: `curl localhost:8080/api/hello`
- From the Mac browser: http://localhost:8080 (forwarded port; real Mac port is printed by the setup script)
- Live frontend dev: `cd ~/app/frontend && npm run dev` (Vite on :5173, proxies `/api` to :8080)

## Tools & logs
- Add Go deps: `cd backend && go get <pkg> && go mod tidy`. Add npm deps: `cd frontend && npm install <pkg>`.
- Logs: `sudo journalctl -u app-backend -f`, status: `sudo systemctl status app-backend`.

## Rules
- Keep ports 8080 (app) and 5173 (dev). Do not run the app as root. Do not commit `node_modules`, `dist`, `bin`.
EOF

cat > "$PAYLOAD/app-backend.service" <<'EOF'
[Unit]
Description=Go backend (serves API + built React)
After=network-online.target
Wants=network-online.target

[Service]
User=@USER@
WorkingDirectory=/home/@USER@/app/backend
Environment=PORT=8080
Environment=STATIC_DIR=/home/@USER@/app/frontend/dist
ExecStart=/home/@USER@/app/bin/server
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# ---- In-VM setup script (runs once from cloud-init, logs to /var/log/app-setup.log) ----
cat > "$PAYLOAD/setup-app.sh" <<'EOF'
#!/usr/bin/env bash
set -u
APP_USER="${APP_USER:?APP_USER missing}"
HOME_DIR="/home/$APP_USER"
LOG=/var/log/app-setup.log
exec >>"$LOG" 2>&1

step() { echo; echo "[$(date +%T)] ### $*"; }
fail() { echo "[$(date +%T)] FAILED: $*"; echo "FAILED: $*" > /var/lib/app-setup.status; exit 1; }
as_user() { sudo -u "$APP_USER" -H bash -lc "$*"; }
retry() { local n=$1; shift; local i; for i in $(seq 1 "$n"); do "$@" && return 0; echo "attempt $i/$n failed"; sleep 5; done; return 1; }

echo "RUNNING" > /var/lib/app-setup.status
step "Tool versions"
go version       || fail "go not installed"
node -v          || fail "node not installed"
npm -v           || fail "npm not installed"
git --version

step "Installing project into $HOME_DIR/app"
mkdir -p "$HOME_DIR/app"
cp -a /opt/bootstrap/app/. "$HOME_DIR/app/"
cp "$HOME_DIR/app/LLM_PROMPT.md" "$HOME_DIR/app/AGENTS.md"
cp "$HOME_DIR/app/LLM_PROMPT.md" "$HOME_DIR/app/CLAUDE.md"
chmod +x "$HOME_DIR/app/deploy.sh"
chown -R "$APP_USER:$APP_USER" "$HOME_DIR/app"

step "Building Go backend"
as_user "mkdir -p ~/app/bin && cd ~/app/backend && go build -o ../bin/server ." || fail "go build"

step "Installing npm dependencies"
retry 3 as_user "cd ~/app/frontend && npm install --no-audit --no-fund" || fail "npm install"

step "Building React frontend"
as_user "cd ~/app/frontend && npm run build" || fail "npm run build"

step "Installing systemd service"
sed "s/@USER@/$APP_USER/g" /opt/bootstrap/app-backend.service > /etc/systemd/system/app-backend.service
systemctl daemon-reload
systemctl enable --now app-backend || fail "systemctl enable app-backend"

step "Health check (inside the VM)"
OK=0
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8080/api/hello; then OK=1; echo; break; fi
  sleep 2
done
[ "$OK" = 1 ] || fail "backend did not answer on :8080"
curl -fsS http://127.0.0.1:8080/ | grep -q 'id="root"' || fail "React index.html not served"

step "Git init"
as_user "cd ~/app && git init -q && git add -A && git -c user.name=setup -c user.email=setup@localhost commit -qm 'Initial Go + React hello world'" || echo "git init skipped"

echo "OK" > /var/lib/app-setup.status
step "APP SETUP COMPLETE"
EOF
chmod +x "$PAYLOAD/setup-app.sh" "$PAYLOAD/app/deploy.sh"

PAYLOAD_B64="$(COPYFILE_DISABLE=1 tar czf - -C "$PAYLOAD" . | base64 | tr -d '\n')"
info "Payload size (base64): ${#PAYLOAD_B64} bytes"
cp -R "$PAYLOAD" "$LOG_DIR/${VM_NAME}-${TS}-payload"   # readable copy for debugging

# ---------- cloud-init seed ----------
log "Building cloud-init seed disk"
SEEDDIR="$WORK/seed"; mkdir -p "$SEEDDIR"

cat > "$SEEDDIR/meta-data" <<EOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${VM_NAME}
EOF

PKG_YAML=""; for p in $PACKAGES; do PKG_YAML+="  - $p"$'\n'; done

cat > "$SEEDDIR/user-data" <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
timezone: ${TIMEZONE}

users:
  - name: ${VM_USER}
    gecos: ${VM_USER}
    shell: /bin/bash
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    plain_text_passwd: '${VM_PASSWORD}'
    ssh_authorized_keys:
      - ${PUBKEY}

ssh_pwauth: true
disable_root: true

write_files:
  - path: /etc/ssh/sshd_config.d/99-password-login.conf
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
      PermitRootLogin no
  - path: /opt/bootstrap/payload.tgz
    encoding: b64
    permissions: '0600'
    content: ${PAYLOAD_B64}

package_update: true
package_upgrade: true
packages:
${PKG_YAML}
runcmd:
  - [ systemctl, enable, --now, ssh ]
  - [ systemctl, restart, ssh ]
  - [ bash, -c, "tar xzf /opt/bootstrap/payload.tgz -C /opt/bootstrap" ]
  - [ bash, -c, "systemctl enable --now unattended-upgrades || true" ]
  - [ bash, -c, "APP_USER=${VM_USER} bash /opt/bootstrap/setup-app.sh || true" ]
  - [ bash, -c, "apt-get -y autoremove --purge; apt-get clean" ]

final_message: "cloud-init finished after \$UPTIME seconds"
EOF
# readable copy for debugging (password and payload masked)
sed -E -e "s/plain_text_passwd: '.*'/plain_text_passwd: '***'/" -e "s/(content: ).{200,}/\1<base64 payload omitted>/" \
  "$SEEDDIR/user-data" > "$LOG_DIR/${VM_NAME}-${TS}-user-data.yaml"
info "user-data copy (masked): $LOG_DIR/${VM_NAME}-${TS}-user-data.yaml"

SEEDRAW="$WORK/seed.img"
dd if=/dev/zero of="$SEEDRAW" bs=1m count=8 2>/dev/null
DEV="$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$SEEDRAW" 2>/dev/null | awk 'NR==1{print $1}')"
[[ -n "$DEV" ]] || die "hdiutil attach failed for seed image."
newfs_msdos -F 12 -v CIDATA "${DEV/disk/rdisk}" >/dev/null
hdiutil detach "$DEV" >/dev/null 2>&1
MNT="$WORK/mnt"; mkdir -p "$MNT"
hdiutil attach -imagekey diskimage-class=CRawDiskImage -mountpoint "$MNT" "$SEEDRAW" >/dev/null 2>&1
cp "$SEEDDIR/user-data" "$SEEDDIR/meta-data" "$MNT/"
info "Seed disk content: $(ls "$MNT" | tr '\n' ' ')"
sync
hdiutil detach "$MNT" >/dev/null 2>&1
VBoxManage convertfromraw "$SEEDRAW" "$SEED" --format VDI >/dev/null

# ---------- Create VM ----------
OSTYPE="Debian_arm64"
VBoxManage list ostypes | grep -q "ID:.*Debian${DEBIAN_VERSION}_arm64" && OSTYPE="Debian${DEBIAN_VERSION}_arm64"

log "Creating VM '$VM_NAME' (ostype $OSTYPE, ${RAM_MB}MB RAM, ${CPUS} CPUs)"
VBoxManage createvm --name "$VM_NAME" --ostype "$OSTYPE" --basefolder "$VM_BASE" --register >/dev/null
VBoxManage modifyvm "$VM_NAME" \
  --memory "$RAM_MB" --cpus "$CPUS" --firmware efi \
  --nic1 nat \
  --audio-driver none --boot1 disk --boot2 none --boot3 none --boot4 none

# Port forwarding Mac -> VM
VBoxManage modifyvm "$VM_NAME" --natpf1 "ssh,tcp,${BIND_IP},${SSH_PORT},,22"
VBoxManage modifyvm "$VM_NAME" --natpf1 "http,tcp,${BIND_IP},${HTTP_PORT},,8080"
VBoxManage modifyvm "$VM_NAME" --natpf1 "vitedev,tcp,${BIND_IP},${DEV_PORT},,5173"
info "Port forwards: $(VBoxManage showvminfo "$VM_NAME" --machinereadable | grep -E '^Forwarding' | tr '\n' ' ')"

# genericcloud kernel only ships virtio drivers -> virtio-net is required
if VBoxManage modifyvm "$VM_NAME" --nic-type1 virtio 2>/dev/null \
   || VBoxManage modifyvm "$VM_NAME" --nictype1 virtio 2>/dev/null; then
  info "NIC type set to virtio"
else
  warn "Could not set virtio NIC. If SSH fails, retry with IMAGE_VARIANT=generic"
fi
VBoxManage modifyvm "$VM_NAME" --cable-connected1 on 2>/dev/null || true

VBoxManage storagectl "$VM_NAME" --name "VirtioSCSI" --add virtio-scsi --controller VirtIO
VBoxManage storageattach "$VM_NAME" --storagectl "VirtioSCSI" --port 0 --device 0 --type hdd --medium "$DISK"
VBoxManage storageattach "$VM_NAME" --storagectl "VirtioSCSI" --port 1 --device 0 --type hdd --medium "$SEED"

# ---------- Start with fallbacks (fixes VERR_PGM_RAM_CONFLICT on 'vga') ----------
STARTED=0; USED_RAM=""; USED_GFX=""
for RAM_TRY in "$RAM_MB" 8192 6144 4096; do
  for GFX in qemuramfb vmsvga vboxvga none; do
    log "Start attempt: RAM=${RAM_TRY}MB graphics=${GFX}"
    VBoxManage modifyvm "$VM_NAME" --memory "$RAM_TRY" 2>/dev/null || true
    if ! VBoxManage modifyvm "$VM_NAME" --graphicscontroller "$GFX" --vram 16 2>/dev/null; then
      info "graphics controller '$GFX' not supported, skipping"; continue
    fi
    if OUT="$(VBoxManage startvm "$VM_NAME" --type headless 2>&1)"; then
      sleep 5
      STATE="$(vm_state)"; info "VM state after start: $STATE"
      if [[ "$STATE" == "running" ]]; then STARTED=1; USED_RAM="$RAM_TRY"; USED_GFX="$GFX"; break 2; fi
    fi
    info "failed: $(echo "$OUT" | grep -iE 'error|VERR' | head -2)"
    VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
    sleep 2
  done
done
[[ $STARTED -eq 1 ]] || die "VM could not start with any RAM/graphics combination."
log "VM running (RAM=${USED_RAM}MB, graphics=${USED_GFX})"

# ---------- Wait for SSH ----------
log "Waiting for SSH (max ${SSH_WAIT_SECONDS}s), screenshots every 60s in $LOG_DIR"
START=$SECONDS; LAST_SHOT=0; OK=0
while (( SECONDS - START < SSH_WAIT_SECONDS )); do
  ELAPSED=$((SECONDS-START)); STATE="$(vm_state)"
  [[ "$STATE" == "running" ]] || die "VM is no longer running (state: $STATE)."
  if vm_ssh true 2>/dev/null; then OK=1; break; fi
  PORT="closed"; nc -z -w 2 127.0.0.1 "$SSH_PORT" 2>/dev/null && PORT="open (sshd answering, auth not ready yet)"
  info "t+${ELAPSED}s  vm=${STATE}  host-port ${SSH_PORT}: ${PORT}"
  if (( ELAPSED - LAST_SHOT >= 60 )); then screenshot "t${ELAPSED}s"; LAST_SHOT=$ELAPSED; fi
  sleep 10
done
[[ $OK -eq 1 ]] || die "SSH never came up after ${SSH_WAIT_SECONDS}s."
log "SSH is up after $((SECONDS-START))s"

# ---------- Wait for cloud-init + app build (live progress) ----------
log "Waiting for cloud-init, package install and app build (max ${CLOUDINIT_WAIT_SECONDS}s)"
START=$SECONDS; DONE=0
while (( SECONDS - START < CLOUDINIT_WAIT_SECONDS )); do
  CI="$(vm_ssh 'cloud-init status 2>/dev/null | head -1' 2>/dev/null || true)"
  APP="$(vm_ssh 'cat /var/lib/app-setup.status 2>/dev/null' 2>/dev/null || true)"
  LAST="$(vm_ssh 'sudo tail -n 1 /var/log/app-setup.log 2>/dev/null' 2>/dev/null | cut -c1-90 || true)"
  info "t+$((SECONDS-START))s  cloud-init: ${CI:-n/a} | app: ${APP:-pending} | ${LAST}"
  case "$CI" in *done*|*error*|*degraded*) DONE=1; break ;; esac
  sleep 15
done
[[ $DONE -eq 1 ]] || die "cloud-init did not finish within ${CLOUDINIT_WAIT_SECONDS}s."

APP_STATUS="$(vm_ssh 'cat /var/lib/app-setup.status 2>/dev/null' || true)"
echo "--- app setup log (last 40 lines) ---"
vm_ssh 'sudo tail -n 40 /var/log/app-setup.log' || true
echo "--- failed systemd units (apparmor etc. are informational) ---"
vm_ssh 'systemctl --failed --no-legend' || true
[[ "$APP_STATUS" == "OK" ]] || die "App setup did not succeed (status: ${APP_STATUS:-unknown})."

# ---------- End-to-end test from the Mac ----------
log "Testing from the Mac: http://localhost:${HTTP_PORT}"
PASS=1
API="$(curl -fsS --max-time 10 "http://127.0.0.1:${HTTP_PORT}/api/hello" 2>&1)" \
  && info "API    OK: $API" || { warn "API test failed: $API"; PASS=0; }
PAGE="$(curl -fsS --max-time 10 "http://127.0.0.1:${HTTP_PORT}/" 2>&1)" || PAGE=""
if echo "$PAGE" | grep -q 'id="root"'; then
  info "PAGE   OK: React index.html served"
  JS="$(echo "$PAGE" | grep -o '/assets/[^"]*\.js' | head -1)"
  if [[ -n "$JS" ]] && curl -fsS --max-time 10 -o /dev/null "http://127.0.0.1:${HTTP_PORT}${JS}"; then
    info "ASSET  OK: ${JS}"
  else warn "React JS asset not reachable (${JS:-none})"; PASS=0; fi
else
  warn "React page not served correctly"; PASS=0
fi
[[ $PASS -eq 1 ]] || die "End-to-end test from the Mac failed (VM side is OK, check port forwarding)."

# ---------- ssh config ----------
if ! grep -q "^Host ${VM_NAME}\$" "$HOME/.ssh/config" 2>/dev/null; then
  cat >> "$HOME/.ssh/config" <<EOF

Host ${VM_NAME}
  HostName 127.0.0.1
  Port ${SSH_PORT}
  User ${VM_USER}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF
fi

cp "$PAYLOAD/app/LLM_PROMPT.md" "$LOG_DIR/${VM_NAME}-LLM_PROMPT.md"

log "SUCCESS: VM '$VM_NAME' is ready, Hello World is live."
cat <<EOF

  Open in Mac browser:  http://localhost:${HTTP_PORT}        (Go backend + built React)
  Vite dev server:      http://localhost:${DEV_PORT}        (after: cd ~/app/frontend && npm run dev)
  SSH:                  ssh ${VM_NAME}    or    ssh ${VM_USER}@127.0.0.1 -p ${SSH_PORT}   (password: ${VM_PASSWORD})
  Project in the VM:    ~/app   (backend/ = Go, frontend/ = React)
  Redeploy in the VM:   ~/app/deploy.sh
  Stop / Start VM:      VBoxManage controlvm ${VM_NAME} acpipoweroff
                        VBoxManage startvm ${VM_NAME} --type headless
  Delete VM:            VBoxManage unregistervm ${VM_NAME} --delete
  Script log:           ${LOGFILE}

  ---------- PROMPT TO GIVE YOUR LLM (also saved in the VM: ~/app/LLM_PROMPT.md, AGENTS.md, CLAUDE.md) ----------
EOF
cat "$PAYLOAD/app/LLM_PROMPT.md"
echo "  -------------------------------------------------------------------------------------------------------"
open "http://localhost:${HTTP_PORT}" 2>/dev/null || true

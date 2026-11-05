# TASK: Build a Cybersecurity Company Website & Admin Panel FROM SCRATCH, and deploy it to a VirtualBox VM over SSH

You build a brand-new application from scratch (new backend code, new frontend code). A Debian VM already exists in VirtualBox on this Mac. First you must FIND the VM and work out how to connect to it. Then you write the code, deploy it with the provided deploy script over SSH, and verify it. Do not add features beyond this spec.

## 0. Step one: find the VM and its connection details (you must do this yourself)

- VM name in VirtualBox: `llm-code-test`. Nothing else about its address is given: discover it.
- Use only `VBoxManage` on the Mac. Run these steps in order and keep the results in shell variables.

```bash
VM=llm-code-test

# 1. Does VirtualBox know the VM?
VBoxManage list vms | grep -F "\"$VM\"" || { echo "VM not found. Registered VMs:"; VBoxManage list vms; exit 1; }

# 2. Is it running? If not, start it headless and wait.
state() { VBoxManage showvminfo "$VM" --machinereadable | awk -F'"' '/^VMState=/{print $2}'; }
echo "state: $(state)"
[ "$(state)" = "running" ] || VBoxManage startvm "$VM" --type headless
# if state is "aborted" or "saved": VBoxManage discardstate "$VM" (if needed), then start again

# 3. Network mode and port-forward rules (this is how you find the "IP")
VBoxManage showvminfo "$VM" --machinereadable | grep -E '^(nic1|nictype1|macaddress1|Forwarding)'
```

How to interpret step 3:
- `nic1="nat"`: the VM sits behind VirtualBox NAT. Its internal address (usually `10.0.2.15`) is NOT reachable from the Mac. Do not try to SSH to it. Connect through the forwarded port instead.
- A rule looks like `Forwarding(0)="ssh,tcp,127.0.0.1,2222,,22"` meaning `name,protocol,hostIP,hostPort,guestIP,guestPort`. Find the rule whose **guest port is 22** -> `SSH_HOST` (hostIP, use `127.0.0.1` if empty) and `SSH_PORT` (hostPort). Find the rule whose guest port is 8080 -> `WEB_PORT`.
- If there is no rule for guest port 22 or 8080, add it live (pick another free host port if busy, check with `nc -z 127.0.0.1 <port>`):
  `VBoxManage controlvm "$VM" natpf1 "ssh,tcp,127.0.0.1,2222,,22"` and
  `VBoxManage controlvm "$VM" natpf1 "http,tcp,127.0.0.1,8080,,8080"`.
- `nic1="bridged"`: the VM has a LAN IP. Find it from the MAC (`macaddress1`) with `arp -a` after a ping sweep of the local subnet, and use that IP with port 22. (Guest Additions are not installed, so `VBoxManage guestproperty` will not work.)
- Wait until the port answers: `nc -z -w 2 $SSH_HOST $SSH_PORT`. A fresh boot can take 1-2 minutes. If it never answers, take a screenshot (`VBoxManage controlvm "$VM" screenshotpng /tmp/vm.png && open /tmp/vm.png`), check `VBoxManage showvminfo "$VM" | grep -i state`, then report the problem instead of continuing.
- Print the discovered values (`SSH_HOST`, `SSH_PORT`, `WEB_PORT`) at the start of your final report.

## 1. SSH access (non-interactive)

- SSH user: `admin`. SSH password: `admin`. Passwordless `sudo` is enabled for this user.
- **The SSH login (`admin`/`admin`, a Linux account) is separate from the website login `admin`/`admin` (an app account in SQLite) that you will create. They only happen to share the same text.**
- Prefer the key that was installed in the VM at creation: `~/.ssh/id_ed25519_vbox` (authorized for user `admin`).
- Define one helper and use it for every VM command:

```bash
SSH_BASE=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ServerAliveInterval=15 -o ConnectTimeout=10)

# Preferred: key
vm() { ssh -i ~/.ssh/id_ed25519_vbox -o IdentitiesOnly=yes -o BatchMode=yes "${SSH_BASE[@]}" admin@"$SSH_HOST" "$@"; }

# Fallback if the key is rejected: password "admin" supplied non-interactively (OpenSSH 8.4+, macOS)
printf '#!/bin/sh\necho admin\n' > /tmp/askpass.sh && chmod +x /tmp/askpass.sh
vm_pw() { SSH_ASKPASS=/tmp/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
          ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no "${SSH_BASE[@]}" admin@"$SSH_HOST" "$@"; }

vm 'echo connected; whoami; hostname; ls ~/app'     # use vm_pw if the key fails
```

- If neither works, do not guess other users: print `ssh -v` output and report.
- Never use interactive prompts or interactive programs. Long commands (the first Go build can take several minutes) must keep the connection alive.
- To copy files, use the same options: `rsync -az --delete --exclude node_modules --exclude dist --exclude data -e "ssh -i ~/.ssh/id_ed25519_vbox -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" ./backend ./frontend admin@$SSH_HOST:app/`. Or write files directly on the VM with `vm 'cat > ~/app/backend/main.go' <<'EOF' ... EOF`.

## 2. Where the code lives

- The project root is `~/app` on the VM (`/home/admin/app`). It is a git repository. All final code must be in `~/app` on the VM. Check `vm 'pwd; echo $HOME'` and `vm 'cat /etc/systemd/system/app-backend.service'` to confirm paths.
- The VM contains a throwaway hello-world in `~/app/backend` and `~/app/frontend`. **Replace it completely**: delete the old source files and build your own from scratch. Do not keep, extend or reuse them.
- Keep the files that belong to the environment: `~/app/deploy.sh`, `~/app/.gitignore` (you may append lines) and the instruction files `AGENTS.md`, `CLAUDE.md`, `LLM_PROMPT.md`.

## 3. Environment and deployment contract (already set up, do not change)

VM: Debian 13 (arm64), 8 GB RAM, 3 CPUs, internet access. Installed: Go (Debian package), Node 20 + npm, build-essential, make, git, curl, wget, jq, rsync, unzip, vim-tiny.

| Item | Value |
|---|---|
| Process | ONE Go process serves both the REST API and the compiled React frontend |
| Port | `8080` inside the VM (Mac reaches it at `http://localhost:$WEB_PORT`). Vite dev server: `5173` |
| Go module | directory `~/app/backend`, module name `app`, entry file `backend/main.go`, package `main` |
| Binary | `~/app/bin/server` (built by `deploy.sh`) |
| systemd service | `app-backend`, runs the binary as user `admin` (never root), working directory `~/app/backend` |
| Env vars set by the service | `PORT=8080`, `STATIC_DIR=/home/admin/app/frontend/dist` |
| Frontend build output | `~/app/frontend/dist` (the backend must serve it, SPA fallback to `index.html` for non-API, non-file paths) |
| DB location | env `DB_PATH`, default `../data/app.db` (resolves to `~/app/data/app.db`; create the folder at startup) |

`~/app/deploy.sh` does, in order:
1. `cd backend && go mod tidy && go build -o ../bin/server .`
2. `cd frontend && npm install && npm run build`
3. `sudo systemctl restart app-backend`
4. health check on `http://127.0.0.1:8080/api/health`

Your code must therefore satisfy:
- `backend/go.mod` (module `app`) exists and `backend/` compiles with `go build .`.
- `frontend/package.json` has a working `build` script producing `frontend/dist/index.html`.
- The server reads `PORT` and `STATIC_DIR` from the environment and serves `GET /api/health` -> `200 {"status":"ok"}`.
- All API routes are under `/api/*`; unknown `/api/*` paths return a JSON 404.
- Frontend API calls use relative URLs only (`fetch('/api/...')`). Never hardcode a host or port.

**Do not modify** `deploy.sh`, the systemd unit, the service name `app-backend`, or the ports. If you believe one must change, stop and report why.

## 4. Deploying (mandatory, always over SSH)

After EVERY code change, deploy and wait for success before continuing:

```bash
vm '~/app/deploy.sh'
```

- Do not replace this with another method: no `go run`, no manually started servers, no `nohup`, no second process on 8080, no building on the Mac and copying binaries.
- `npm run dev` may be used temporarily for frontend work, but the final state must come from `deploy.sh`.
- If deploy fails: read the output, then `vm 'sudo journalctl -u app-backend -n 50 --no-pager'` and `vm 'sudo systemctl status app-backend --no-pager'`, fix the cause, redeploy.
- `sudo` is only for `systemctl`, `journalctl` and optionally `apt-get install -y sqlite3`. Never run the app as root.
- Never delete the SQLite database during deployment.
- Add dependencies on the VM: `cd ~/app/backend && go get <pkg> && go mod tidy`; `cd ~/app/frontend && npm install <pkg>`.
- Use `journalctl -n 100` (not `-f`) so commands terminate.

## 5. Objective and scope

Build a professional website for a **cybersecurity company** (security solutions, threat protection and infrastructure monitoring) with exactly three functionalities:

1. Public landing page.
2. Authentication (login/logout).
3. Admin dashboard with user management.

Out of scope, do not implement: any real security functionality (scanning, detection, SIEM, log collection, uptime or infrastructure monitoring, alerts, incident management, reports, agents), billing, payments, subscriptions, ordering flows, signup/registration, password reset, email, contact forms, profile pages, or any other module. Pricing plans are static marketing content. The dashboard shows no fake threat or monitoring data.

## 6. Stack

- Backend: Go standard library `net/http` (Go 1.22+ method patterns like `"GET /api/users/{id}"` allowed). Extra `.go` files in package `main` are fine.
- Allowed Go dependencies, only these: `modernc.org/sqlite` (pure Go, no CGO; do NOT use `mattn/go-sqlite3`) and `golang.org/x/crypto/bcrypt`. No web framework, router library or ORM. The first compile of modernc sqlite can take a few minutes; this is normal.
- Frontend: React + TypeScript + Vite + Tailwind CSS v4 (`tailwindcss` + `@tailwindcss/vite`, `@import "tailwindcss";` in `src/index.css`) + `react-router-dom`. TypeScript `strict: true`. No other UI framework. Scripts: `dev` (Vite on `0.0.0.0:5173`, proxy `/api` to `http://127.0.0.1:8080`), `build` = `tsc --noEmit && vite build`, `preview`.
- Database: SQLite.
- No external CDN or runtime requests. Use a system font stack or a bundled `@fontsource` package.

## 7. Target layout

```
~/app
├── backend/        main.go (+ db.go, auth.go, users.go optional), go.mod, go.sum
├── frontend/
│   ├── index.html  (SEO tags + JSON-LD, script src=/src/main.tsx)
│   ├── public/     robots.txt, sitemap.xml, favicon.svg, og-image.svg
│   ├── src/        main.tsx, App.tsx, index.css, api.ts, auth context, pages/, components/
│   ├── tsconfig.json, vite.config.ts, package.json
├── data/           app.db (git-ignored, created at runtime)
├── deploy.sh, AGENTS.md, CLAUDE.md, LLM_PROMPT.md, .gitignore
```

## 8. Backend

### Database (create on startup if missing)
- `users`: `id` INTEGER PK AUTOINCREMENT, `username` TEXT NOT NULL UNIQUE COLLATE NOCASE, `password_hash` TEXT NOT NULL, `role` TEXT NOT NULL CHECK(role IN ('admin','user')), `created_at`, `updated_at`.
- `sessions`: `token_hash` TEXT PK, `user_id` INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, `created_at`, `expires_at`.
- Enable foreign keys and a busy timeout.
- **Seed** only when `users` is empty: website account `admin` / `admin`, role `admin`, bcrypt hash. Never re-seed on restart.

### Authentication
- Passwords: bcrypt, never stored or logged in plaintext; hashes never returned by the API.
- Login creates a random 32-byte token; store only its SHA-256 hash in `sessions`. Cookie `session`: `HttpOnly`, `SameSite=Lax`, `Path=/`, 24h expiry, **no `Secure` flag** (plain HTTP on localhost; `Secure` would break login).
- Logout deletes the session row and clears the cookie.
- Same generic error for unknown user and wrong password.
- POST/PUT/DELETE require `Content-Type: application/json` (else 415). Limit bodies to 1 MB (`http.MaxBytesReader`).
- Middleware: `requireAuth` (valid, non-expired session, else 401), `requireAdmin` (role `admin`, else 403).
- Security headers on all responses: `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`. No HSTS and no `Content-Security-Policy` (could break the Vite build).

### API (JSON; errors shaped `{"error":"message"}`)

| Method | Path | Access | Success | Errors |
|---|---|---|---|---|
| GET | `/api/health` | public | 200 `{"status":"ok"}` | |
| POST | `/api/auth/login` | public | 200 `{id,username,role}` + cookie | 400, 401 |
| POST | `/api/auth/logout` | public | 204 (idempotent) | |
| GET | `/api/auth/me` | logged in | 200 `{id,username,role}` | 401 |
| GET | `/api/stats` | admin | 200 `{"total_users":n}` | 401, 403 |
| GET | `/api/users` | admin | 200 `[{id,username,role,created_at}]` | 401, 403 |
| POST | `/api/users` | admin | 201 user object | 400, 401, 403, 409 |
| PUT | `/api/users/{id}` | admin | 200 user object | 400, 401, 403, 404, 409 |
| DELETE | `/api/users/{id}` | admin | 204 | 401, 403, 404, 409 |

### Validation
- `username`: 3-32 chars `[A-Za-z0-9_.-]`, unique case-insensitively (409 on duplicate).
- `password`: 8-72 chars on create; optional on update (empty = unchanged). The seeded `admin/admin` is exempt.
- `role`: `admin` or `user`.
- Unknown JSON fields or malformed bodies: 400. Wrong method: 405.
- 409 safeguards: an admin cannot delete their own account; the last remaining admin cannot be deleted or demoted.
- Deleting a user also removes their sessions.

## 9. Frontend

### Routes
| Path | Page | Access |
|---|---|---|
| `/` | Landing page | public |
| `/login` | Login | public (logged-in admin is redirected to `/admin`) |
| `/admin` | Dashboard | admin only |
| `/admin/users` | User management | admin only |
| `*` | simple 404 page | public |

- On load call `/api/auth/me` to restore the session (show a loading state).
- Not logged in -> redirect to `/login`. Logged in but not admin -> "403 - Access denied" page with a Logout button. Any 401 from the API clears auth state and redirects to `/login`.

### Admin layout
- Sidebar: Dashboard, Users, Logout (collapsible on mobile). Same brand identity as the landing page.
- Dashboard: the exact text **"Welcome, Admin"** and a card with the total number of users (from `/api/stats`).
- Users page: table (username, role badge, created date, actions), "New user" button, create/edit modal or form (username, password required on create and optional on edit, role select), delete with confirmation, own row delete disabled, loading/empty/error states, backend validation errors shown inline.

### Landing page (professional, modern, responsive, accessible)
Invent one fictional cybersecurity brand name and use it everywhere (name, logo mark, tagline, footer, SEO). Tone: trustworthy, clear, professional. Visual direction: deep-navy or dark hero with one strong accent color (cyan, green or electric blue), clean sans-serif typography, subtle grid or shield motifs in inline SVG/CSS. No stock photos, no external images.

Truthfulness rules:
- Do NOT invent certifications or compliance claims (no SOC 2, ISO 27001, PCI-DSS, etc.), awards, customer logos, testimonials, case studies or statistics.
- No absolute promises ("100% secure", "unhackable"); use measured wording ("helps reduce risk", "continuous visibility").
- Any dashboard-looking or threat-map visual must be clearly decorative with no invented numbers.

Required sections:
- Sticky navigation bar with anchor links and a **Login** button (links to `/login`).
- Hero: headline about security solutions, threat protection and infrastructure monitoring; primary CTA (anchor to Pricing), secondary CTA (anchor to Features).
- Features/Services: 6 cards covering the three pillars: security solutions (assessments, architecture, hardening advice), threat protection (detection, incident response, endpoint and network protection), infrastructure monitoring (24/7 monitoring, log visibility, alerting on suspicious activity).
- Pricing: 3 static plans with clearly fictional prices; every CTA just links to `/login`.
- Benefits: qualitative claims only.
- FAQ: accessible accordion (`<details>` or buttons with `aria-expanded`), 5-6 questions.
- Footer: brand, section links, Login link, copyright; no fake address or phone.

Quality bar: semantic HTML (`header`, `nav`, `main`, `section` with `aria-labelledby`, `footer`), exactly one `<h1>`, ordered headings, visible focus states, WCAG AA contrast, mobile-first, strong typography and spacing, respect `prefers-reduced-motion`.

### SEO
- `index.html`: `lang`, title, meta description, canonical, Open Graph (`og:title`, `og:description`, `og:type`, `og:url`, `og:image`, `og:site_name`), Twitter card, theme-color, favicon.
- Static JSON-LD in `index.html`: `Organization`, `WebSite`, `FAQPage` (FAQ JSON-LD must match the visible FAQ text exactly).
- Placeholder domain `https://www.example-cybersec.com` used consistently (canonical, og:url, sitemap, robots, JSON-LD).
- `public/robots.txt`: allow `/`, disallow `/admin`, `/login`, `/api/`, with a `Sitemap:` line. `public/sitemap.xml`: only `/`.
- `/login` and `/admin/*` set `<meta name="robots" content="noindex,nofollow">` at runtime and remove it when leaving.
- Per-route `document.title` via a small hook (no library).
- `favicon.svg` and `og-image.svg` in `public/`, matching the brand (shield or lock motif).

## 10. Repository rules
- `.gitignore` must contain: `node_modules/`, `frontend/dist/`, `bin/`, `data/`, `*.db`, `*.db-wal`, `*.db-shm`.
- Commit on the VM when all checks pass: `vm 'cd ~/app && git add -A && git -c user.name=llm -c user.email=llm@localhost commit -m "Cybersecurity website + admin panel"'`.

## 11. Verification (after the final deploy)

Run these inside the VM (through `vm '...'`, or one script via `vm 'bash -s' <<'EOF' ... EOF`):

```bash
curl -fsS localhost:8080/api/health
systemctl is-active app-backend

curl -fsS -c /tmp/cj -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin"}' localhost:8080/api/auth/login
curl -fsS -b /tmp/cj localhost:8080/api/auth/me
curl -fsS -b /tmp/cj localhost:8080/api/stats
curl -fsS -b /tmp/cj localhost:8080/api/users

# expect 401 without cookie, 401 with wrong password
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/api/users
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"wrong"}' localhost:8080/api/auth/login

# create a regular user, log in as them, expect 403 on /api/users, then delete that user as admin
# persistence: sudo systemctl restart app-backend && sleep 2; log in again; users still exist

curl -fsS localhost:8080/robots.txt
curl -fsS localhost:8080/sitemap.xml
curl -fsS localhost:8080/ | grep -E '<title>|canonical|og:title|ld\+json'
curl -sI localhost:8080/ | grep -iE 'x-content-type-options|x-frame-options|referrer-policy'
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/login   # expect 200
```

From the Mac (use the `WEB_PORT` you discovered in step 0):
```bash
curl -fsS http://localhost:$WEB_PORT/api/health
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:$WEB_PORT/    # expect 200
```

Also confirm: the API never returns `password_hash`; `git status` shows no `node_modules/`, `dist/`, `bin/`, `data/` or `*.db`; no invented certifications or statistics (`grep -riE 'SOC ?2|ISO ?27001|PCI|certified|testimonial' ~/app/frontend/src ~/app/frontend/index.html`); delete test users so only `admin` remains.

## 12. Done when
1. You found the VM `llm-code-test` in VirtualBox and connected over SSH as `admin`, using the discovered host and port.
2. The landing page is complete with all sections, the three pillars and all SEO assets.
3. The website login `admin`/`admin` works through the Go REST API; logout works.
4. Users and sessions persist in SQLite across a service restart.
5. `/admin`, `/admin/users` and their APIs require authentication; user management requires the `admin` role.
6. The dashboard shows "Welcome, Admin" and the total user count.
7. Users can be listed, created, edited (role included) and deleted, with the validation and safeguards above.
8. `~/app/deploy.sh` run over SSH succeeds, `app-backend` is active, and `/api/health` returns OK in the VM and from the Mac.

**Final report:** the discovered `SSH_HOST`, `SSH_PORT`, `WEB_PORT` and the auth method that worked (key or password); the invented brand name; list of files created; the tail of the last `deploy.sh` output; the result of each verification step; a reminder that `https://www.example-cybersec.com` and the fictional prices must be replaced; any deviation from this spec with the reason.

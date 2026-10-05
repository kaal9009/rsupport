# Support SaaS — Phase 1 (testing on Cloudflare, no domain yet)

Master-admin / buyer (reseller) / client remote-support platform, modeled on how
ScreenConnect's reseller flow works. Runs entirely on Cloudflare's free tier
(Workers + Pages + D1) under a `*.workers.dev` URL until a real domain is bought.

## What this Phase-1 build does

- **Master admin panel** (`/admin`) — create buyer accounts, see every buyer's
  clients, see and resolve support-escalation requests.
- **Buyer panel** (`/buyer`) — log in (forced password reset on first login),
  add a client, get a one-time 30-minute install code to hand to that client,
  ask the master admin to step in on a specific client (explicit, logged
  request — the admin never has silent access).
- **Public client page** (`/`) — client enters the code, sees a plain-language
  consent screen naming the buyer's business, and only then can download the
  installer.

## What it deliberately does NOT do

The installer this generates does **not**:
- touch or remove the client's Windows login password
- create a hidden/extra admin account on the client's PC
- enable silent auto-login

Those three stay exclusively in Rohit's own personal dashboard
(`rsupport/dashboard.ps1`), for his own already-authorized clients only. They
are not part of this resold product — a tool other people buy and silently
install on strangers' machines cannot include password-removal or hidden
accounts without becoming a backdoor. See the project memory file for why.

The Phase-1 installer script (`buildInstallerScript` in `worker/index.js`) is
currently a **placeholder** — it explains what Phase 2 replaces it with
(per-buyer Tailscale provisioning for real SSH remote-support, built the
same safe way as the existing `QUICK-INSTALL.bat`: random password per
install, no shared secrets).

## One-time setup

```
cd support-saas
npm install
wrangler login              # opens a browser, log into your existing Cloudflare account
wrangler d1 create support_saas_db
```

Copy the `database_id` it prints into `wrangler.toml` (replace `REPLACE_AFTER_CREATE`), then:

```
npm run db:init:remote
```

Create the first master-admin login:

```
node scripts/seed-admin.mjs you@yourbusiness.com "a-strong-password-here"
```

Copy-paste the `wrangler d1 execute ...` command it prints and run it.

## Deploy

```
npm run deploy
```

This gives you a `https://support-saas.<your-subdomain>.workers.dev` URL.
Open `/admin` and log in with the admin account you just seeded.

## Phase 2 (after this is tested and you're ready to launch)

1. Buy the real domain, point it at this Worker (`wrangler.toml` → routes).
2. Wire real Tailscale provisioning into `buildInstallerScript()` — each
   buyer gets their own Tailscale tag so their clients are isolated from
   every other buyer's.
3. Add email delivery for the buyer's temp password (currently shown once
   in the admin panel — you copy-paste it yourself).

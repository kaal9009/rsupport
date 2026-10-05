-- Master admin (single row, seeded manually — see README)
CREATE TABLE IF NOT EXISTS admins (
  id TEXT PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  password_salt TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Buyers (resellers / technicians who buy the tool)
CREATE TABLE IF NOT EXISTS buyers (
  id TEXT PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  business_name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  password_salt TEXT NOT NULL,
  must_reset_password INTEGER NOT NULL DEFAULT 1,
  status TEXT NOT NULL DEFAULT 'active', -- active | suspended
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Clients each buyer has added to their own dashboard
CREATE TABLE IF NOT EXISTS clients (
  id TEXT PRIMARY KEY,
  buyer_id TEXT NOT NULL REFERENCES buyers(id),
  label TEXT NOT NULL,             -- buyer's own name for this client/PC
  tailscale_ip TEXT,               -- filled in once the install completes
  status TEXT NOT NULL DEFAULT 'pending', -- pending | online | offline
  admin_support_allowed INTEGER NOT NULL DEFAULT 0, -- buyer's consent toggle (see below)
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_seen_at TEXT
);

-- One-time install codes a buyer generates for a new client.
-- The public install page looks a code up here, never anything else.
CREATE TABLE IF NOT EXISTS install_codes (
  code TEXT PRIMARY KEY,           -- short human-typeable code, e.g. "7F3K-9Q2L"
  buyer_id TEXT NOT NULL REFERENCES buyers(id),
  client_id TEXT NOT NULL REFERENCES clients(id),
  expires_at TEXT NOT NULL,
  used_at TEXT,
  consented_at TEXT,               -- set only after the client ticks the consent screen
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Login sessions (admin + buyer), cookie-based
CREATE TABLE IF NOT EXISTS sessions (
  token TEXT PRIMARY KEY,
  subject_type TEXT NOT NULL,      -- 'admin' | 'buyer'
  subject_id TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Audit log: every time the master admin (or anyone) touches a buyer's client,
-- it's recorded here. Required before any escalation support happens.
CREATE TABLE IF NOT EXISTS support_escalations (
  id TEXT PRIMARY KEY,
  client_id TEXT NOT NULL REFERENCES clients(id),
  buyer_id TEXT NOT NULL REFERENCES buyers(id),
  requested_by TEXT NOT NULL,      -- buyer id who asked admin to step in
  note TEXT,
  resolved INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_clients_buyer ON clients(buyer_id);
CREATE INDEX IF NOT EXISTS idx_codes_buyer ON install_codes(buyer_id);
CREATE INDEX IF NOT EXISTS idx_sessions_subject ON sessions(subject_type, subject_id);

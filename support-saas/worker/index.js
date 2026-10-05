import { hashPassword, verifyPassword, randomInstallCode, randomTempPassword, randomToken } from "./crypto.js";
import { createSession, sessionCookie, clearSessionCookie, readSessionToken, requireSession, destroySession } from "./session.js";

const json = (data, init = {}) =>
  new Response(JSON.stringify(data), {
    ...init,
    headers: { "content-type": "application/json", ...(init.headers || {}) },
  });
const bad = (msg, status = 400) => json({ error: msg }, { status });

const INSTALL_CODE_TTL_MIN = 30; // a generated code is only valid for 30 minutes if unused

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    const db = env.DB;

    try {
      // ---------- Admin auth ----------
      if (path === "/api/admin/login" && request.method === "POST") {
        const { email, password } = await request.json();
        const admin = await db.prepare("SELECT * FROM admins WHERE email = ?").bind(email).first();
        if (!admin || !(await verifyPassword(password, admin.password_hash, admin.password_salt))) {
          return bad("Invalid email or password", 401);
        }
        const { token, expires } = await createSession(db, "admin", admin.id);
        return json({ ok: true }, { headers: { "Set-Cookie": sessionCookie(token, expires) } });
      }

      if (path === "/api/admin/logout" && request.method === "POST") {
        await destroySession(db, readSessionToken(request));
        return json({ ok: true }, { headers: { "Set-Cookie": clearSessionCookie() } });
      }

      // ---------- Admin: buyer management ----------
      if (path === "/api/admin/buyers" && request.method === "GET") {
        const admin = await requireSession(request, db, "admin");
        if (!admin) return bad("Not logged in", 401);
        const { results } = await db
          .prepare("SELECT id, email, business_name, status, must_reset_password, created_at FROM buyers ORDER BY created_at DESC")
          .all();
        return json({ buyers: results });
      }

      if (path === "/api/admin/buyers" && request.method === "POST") {
        const admin = await requireSession(request, db, "admin");
        if (!admin) return bad("Not logged in", 401);
        const { email, business_name } = await request.json();
        if (!email || !business_name) return bad("email and business_name are required");
        const existing = await db.prepare("SELECT id FROM buyers WHERE email = ?").bind(email).first();
        if (existing) return bad("A buyer with this email already exists");

        const tempPassword = randomTempPassword();
        const { hash, salt } = await hashPassword(tempPassword);
        const id = randomToken(12);
        await db
          .prepare(
            "INSERT INTO buyers (id, email, business_name, password_hash, password_salt, must_reset_password) VALUES (?, ?, ?, ?, ?, 1)"
          )
          .bind(id, email, business_name, hash, salt)
          .run();

        // Temp password is returned ONCE, here, to the admin — never stored in plaintext, never emailed by this API.
        return json({ ok: true, buyer: { id, email, business_name }, temp_password: tempPassword });
      }

      // ---------- Admin: view all clients across all buyers ----------
      if (path === "/api/admin/clients" && request.method === "GET") {
        const admin = await requireSession(request, db, "admin");
        if (!admin) return bad("Not logged in", 401);
        const { results } = await db
          .prepare(
            `SELECT c.id, c.label, c.status, c.admin_support_allowed, c.last_seen_at,
                    b.id as buyer_id, b.business_name, b.email as buyer_email
             FROM clients c JOIN buyers b ON b.id = c.buyer_id
             ORDER BY c.created_at DESC`
          )
          .all();
        return json({ clients: results });
      }

      // ---------- Admin: open escalations needing attention ----------
      if (path === "/api/admin/escalations" && request.method === "GET") {
        const admin = await requireSession(request, db, "admin");
        if (!admin) return bad("Not logged in", 401);
        const { results } = await db
          .prepare(
            `SELECT e.*, c.label as client_label, b.business_name
             FROM support_escalations e
             JOIN clients c ON c.id = e.client_id
             JOIN buyers b ON b.id = e.buyer_id
             WHERE e.resolved = 0
             ORDER BY e.created_at ASC`
          )
          .all();
        return json({ escalations: results });
      }

      if (path.match(/^\/api\/admin\/escalations\/[^/]+\/resolve$/) && request.method === "POST") {
        const admin = await requireSession(request, db, "admin");
        if (!admin) return bad("Not logged in", 401);
        const id = path.split("/")[4];
        await db.prepare("UPDATE support_escalations SET resolved = 1 WHERE id = ?").bind(id).run();
        return json({ ok: true });
      }

      // ---------- Buyer auth ----------
      if (path === "/api/buyer/login" && request.method === "POST") {
        const { email, password } = await request.json();
        const buyer = await db.prepare("SELECT * FROM buyers WHERE email = ?").bind(email).first();
        if (!buyer || buyer.status !== "active" || !(await verifyPassword(password, buyer.password_hash, buyer.password_salt))) {
          return bad("Invalid email or password", 401);
        }
        const { token, expires } = await createSession(db, "buyer", buyer.id);
        return json(
          { ok: true, must_reset_password: !!buyer.must_reset_password },
          { headers: { "Set-Cookie": sessionCookie(token, expires) } }
        );
      }

      if (path === "/api/buyer/logout" && request.method === "POST") {
        await destroySession(db, readSessionToken(request));
        return json({ ok: true }, { headers: { "Set-Cookie": clearSessionCookie() } });
      }

      if (path === "/api/buyer/reset-password" && request.method === "POST") {
        const session = await requireSession(request, db, "buyer");
        if (!session) return bad("Not logged in", 401);
        const { new_password } = await request.json();
        if (!new_password || new_password.length < 10) return bad("Password must be at least 10 characters");
        const { hash, salt } = await hashPassword(new_password);
        await db
          .prepare("UPDATE buyers SET password_hash = ?, password_salt = ?, must_reset_password = 0 WHERE id = ?")
          .bind(hash, salt, session.subject_id)
          .run();
        return json({ ok: true });
      }

      if (path === "/api/buyer/me" && request.method === "GET") {
        const session = await requireSession(request, db, "buyer");
        if (!session) return bad("Not logged in", 401);
        const buyer = await db
          .prepare("SELECT id, email, business_name, must_reset_password FROM buyers WHERE id = ?")
          .bind(session.subject_id)
          .first();
        return json({ buyer });
      }

      // ---------- Buyer: clients ----------
      if (path === "/api/buyer/clients" && request.method === "GET") {
        const session = await requireSession(request, db, "buyer");
        if (!session) return bad("Not logged in", 401);
        const { results } = await db
          .prepare("SELECT * FROM clients WHERE buyer_id = ? ORDER BY created_at DESC")
          .bind(session.subject_id)
          .all();
        return json({ clients: results });
      }

      if (path === "/api/buyer/clients" && request.method === "POST") {
        const session = await requireSession(request, db, "buyer");
        if (!session) return bad("Not logged in", 401);
        const { label } = await request.json();
        if (!label) return bad("label is required");

        const clientId = randomToken(12);
        await db
          .prepare("INSERT INTO clients (id, buyer_id, label, status) VALUES (?, ?, ?, 'pending')")
          .bind(clientId, session.subject_id, label)
          .run();

        const code = randomInstallCode();
        const expires = new Date(Date.now() + INSTALL_CODE_TTL_MIN * 60 * 1000).toISOString();
        await db
          .prepare("INSERT INTO install_codes (code, buyer_id, client_id, expires_at) VALUES (?, ?, ?, ?)")
          .bind(code, session.subject_id, clientId, expires)
          .run();

        return json({ ok: true, client_id: clientId, code, expires_at: expires });
      }

      // Buyer asks the master admin to step in on one of their clients (explicit, logged consent)
      if (path === "/api/buyer/escalate" && request.method === "POST") {
        const session = await requireSession(request, db, "buyer");
        if (!session) return bad("Not logged in", 401);
        const { client_id, note } = await request.json();
        const client = await db
          .prepare("SELECT * FROM clients WHERE id = ? AND buyer_id = ?")
          .bind(client_id, session.subject_id)
          .first();
        if (!client) return bad("Client not found", 404);

        await db.prepare("UPDATE clients SET admin_support_allowed = 1 WHERE id = ?").bind(client_id).run();
        const id = randomToken(12);
        await db
          .prepare(
            "INSERT INTO support_escalations (id, client_id, buyer_id, requested_by, note) VALUES (?, ?, ?, ?, ?)"
          )
          .bind(id, client_id, session.subject_id, session.subject_id, note || "")
          .run();
        return json({ ok: true });
      }

      // ---------- Public: install code lookup + consent + download ----------
      // No auth here on purpose — this is the page the END CLIENT (not the buyer) opens.
      if (path.match(/^\/api\/install\/[^/]+$/) && request.method === "GET") {
        const code = path.split("/")[3];
        const row = await db
          .prepare(
            `SELECT ic.*, b.business_name FROM install_codes ic
             JOIN buyers b ON b.id = ic.buyer_id
             WHERE ic.code = ?`
          )
          .bind(code)
          .first();
        if (!row) return bad("Invalid code", 404);
        if (row.used_at) return bad("This code has already been used", 410);
        if (new Date(row.expires_at) < new Date()) return bad("This code has expired — ask for a new one", 410);
        return json({ business_name: row.business_name, consented: !!row.consented_at });
      }

      if (path.match(/^\/api\/install\/[^/]+\/consent$/) && request.method === "POST") {
        const code = path.split("/")[3];
        const row = await db.prepare("SELECT * FROM install_codes WHERE code = ?").bind(code).first();
        if (!row) return bad("Invalid code", 404);
        if (row.used_at) return bad("This code has already been used", 410);
        if (new Date(row.expires_at) < new Date()) return bad("This code has expired", 410);
        await db.prepare("UPDATE install_codes SET consented_at = datetime('now') WHERE code = ?").bind(code).run();
        return json({ ok: true });
      }

      if (path.match(/^\/api\/install\/[^/]+\/download$/) && request.method === "GET") {
        const code = path.split("/")[3];
        const row = await db.prepare("SELECT * FROM install_codes WHERE code = ?").bind(code).first();
        if (!row) return bad("Invalid code", 404);
        if (!row.consented_at) return bad("Please accept the consent screen first", 403);
        if (row.used_at) return bad("This code has already been used", 410);
        if (new Date(row.expires_at) < new Date()) return bad("This code has expired", 410);

        await db
          .prepare("UPDATE install_codes SET used_at = datetime('now') WHERE code = ?")
          .bind(code)
          .run();
        await db.prepare("UPDATE clients SET status = 'awaiting_connection' WHERE id = ?").bind(row.client_id).run();

        const script = buildInstallerScript({ code, clientId: row.client_id, buyerId: row.buyer_id });
        return new Response(script, {
          headers: {
            "content-type": "application/octet-stream",
            "content-disposition": 'attachment; filename="SUPPORT-SETUP.bat"',
          },
        });
      }

      // ---------- Static pages ----------
      // /install/<code> is a client-side page (code read from the URL by JS);
      // always serve the same install/index.html for any code.
      if (path.match(/^\/install\/[^/]+$/) && request.method === "GET") {
        return env.ASSETS.fetch(new Request(new URL("/install/index.html", url.origin), request));
      }

      return env.ASSETS.fetch(request);
    } catch (err) {
      return bad(`Server error: ${err.message}`, 500);
    }
  },
};

// Phase-1 installer: plain remote-support agent only.
// Deliberately does NOT touch the client's Windows password, does NOT create a
// hidden admin account, and does NOT enable silent auto-login — those stay
// Rohit's own personal-dashboard-only recovery tools and are never shipped in
// anything a reseller hands to a third party.
function buildInstallerScript({ code, clientId, buyerId }) {
  return `@echo off
:: Remote support setup — code ${code}
:: This installs a support agent (SSH + Tailscale) so a technician can connect
:: to help you. It does NOT change your Windows login password and does NOT
:: create any new account on this PC. You can remove it at any time.
setlocal

echo ============================================
echo   Setting up your remote support connection
echo ============================================
echo Client reference: ${clientId}

:: TODO (Phase 2): fetch this client's assigned Tailscale key from the backend
:: at install time, scoped to buyer ${buyerId}'s tag, instead of embedding one
:: statically here.

echo.
echo This is a placeholder installer — Phase 2 wires in real per-buyer
echo Tailscale provisioning. See README.md "Phase 2" section.
pause
`;
}

import { randomToken } from "./crypto.js";

const SESSION_DAYS = 7;
const COOKIE_NAME = "sid";

export async function createSession(db, subjectType, subjectId) {
  const token = randomToken(32);
  const expires = new Date(Date.now() + SESSION_DAYS * 86400 * 1000).toISOString();
  await db
    .prepare(
      "INSERT INTO sessions (token, subject_type, subject_id, expires_at) VALUES (?, ?, ?, ?)"
    )
    .bind(token, subjectType, subjectId, expires)
    .run();
  return { token, expires };
}

export function sessionCookie(token, expires) {
  return `${COOKIE_NAME}=${token}; Path=/; HttpOnly; Secure; SameSite=Strict; Expires=${new Date(
    expires
  ).toUTCString()}`;
}

export function clearSessionCookie() {
  return `${COOKIE_NAME}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0`;
}

export function readSessionToken(request) {
  const cookie = request.headers.get("Cookie") || "";
  const match = cookie.match(new RegExp(`${COOKIE_NAME}=([^;]+)`));
  return match ? match[1] : null;
}

export async function requireSession(request, db, expectedType) {
  const token = readSessionToken(request);
  if (!token) return null;
  const row = await db
    .prepare(
      "SELECT * FROM sessions WHERE token = ? AND subject_type = ? AND expires_at > datetime('now')"
    )
    .bind(token, expectedType)
    .first();
  return row || null;
}

export async function destroySession(db, token) {
  if (!token) return;
  await db.prepare("DELETE FROM sessions WHERE token = ?").bind(token).run();
}

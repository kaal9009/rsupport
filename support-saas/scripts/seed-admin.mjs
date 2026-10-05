// Usage: node scripts/seed-admin.mjs you@example.com "your-new-password"
// Prints a SQL command — run it with:
//   wrangler d1 execute support_saas_db --remote --command "...the printed SQL..."
import { randomUUID, webcrypto as crypto } from "node:crypto";

const [, , email, password] = process.argv;
if (!email || !password) {
  console.error('Usage: node scripts/seed-admin.mjs <email> "<password>"');
  process.exit(1);
}
if (password.length < 10) {
  console.error("Password must be at least 10 characters.");
  process.exit(1);
}

const ITER = 100000;
async function hashPassword(pw) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const keyMaterial = await crypto.subtle.importKey("raw", new TextEncoder().encode(pw), "PBKDF2", false, ["deriveBits"]);
  const derived = await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations: ITER, hash: "SHA-256" }, keyMaterial, 256);
  const toHex = (b) => Array.from(new Uint8Array(b), (x) => x.toString(16).padStart(2, "0")).join("");
  return { hash: toHex(derived), salt: toHex(salt) };
}

const { hash, salt } = await hashPassword(password);
const id = randomUUID();
const sql = `INSERT INTO admins (id, email, password_hash, password_salt) VALUES ('${id}', '${email.replace(/'/g, "''")}', '${hash}', '${salt}');`;

console.log("\nRun this against your D1 database:\n");
console.log(`wrangler d1 execute support_saas_db --remote --command "${sql}"\n`);

// Password hashing (PBKDF2 via Web Crypto — available natively in Workers, no deps)
const ITER = 100000;

export async function hashPassword(password, saltHex) {
  const enc = new TextEncoder();
  const salt = saltHex
    ? hexToBytes(saltHex)
    : crypto.getRandomValues(new Uint8Array(16));
  const keyMaterial = await crypto.subtle.importKey(
    "raw", enc.encode(password), "PBKDF2", false, ["deriveBits"]
  );
  const derived = await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt, iterations: ITER, hash: "SHA-256" },
    keyMaterial,
    256
  );
  return { hash: bytesToHex(new Uint8Array(derived)), salt: bytesToHex(salt) };
}

export async function verifyPassword(password, hashHex, saltHex) {
  const { hash } = await hashPassword(password, saltHex);
  return timingSafeEqual(hash, hashHex);
}

export function randomToken(bytes = 32) {
  return bytesToHex(crypto.getRandomValues(new Uint8Array(bytes)));
}

// Short, human-typeable install code: e.g. "7F3K-9Q2L" (no 0/O/1/I to avoid confusion)
const CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
export function randomInstallCode() {
  const pick = (n) => {
    const out = [];
    const rand = crypto.getRandomValues(new Uint8Array(n));
    for (let i = 0; i < n; i++) out.push(CODE_ALPHABET[rand[i] % CODE_ALPHABET.length]);
    return out.join("");
  };
  return `${pick(4)}-${pick(4)}`;
}

export function randomTempPassword() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%";
  const rand = crypto.getRandomValues(new Uint8Array(14));
  return Array.from(rand, (b) => chars[b % chars.length]).join("");
}

function bytesToHex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}
function hexToBytes(hex) {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
  return out;
}
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Local stand-in for Supabase Auth plus a proxy to PostgREST.
// The published site never uses this. It talks to a real Supabase project.
import http from "node:http";
import { createHmac, randomBytes, scryptSync, timingSafeEqual } from "node:crypto";
import { pathToFileURL } from "node:url";
import pg from "pg";

const secret = process.env.ITT_JWT_SECRET || "itt-local-test-secret-not-for-production-00";
const port = Number(process.env.ITT_GATEWAY_PORT || 54321);
const postgrestOrigin = process.env.ITT_POSTGREST_URL || "http://127.0.0.1:3001";
const databaseUrl = process.env.ITT_ADMIN_URL || "postgres://itt_admin:itt_local_only@127.0.0.1:5432/itt_diary";

export function hashPassword(password) {
  const salt = randomBytes(16).toString("hex");
  const hash = scryptSync(password, salt, 32).toString("hex");
  return `scrypt$${salt}$${hash}`;
}

export function verifyPassword(password, stored) {
  if (!stored) return false;
  const [kind, salt, hash] = String(stored).split("$");
  if (kind !== "scrypt" || !salt || !hash) return false;
  const next = scryptSync(password, salt, 32);
  const prev = Buffer.from(hash, "hex");
  if (next.length !== prev.length) return false;
  return timingSafeEqual(next, prev);
}

function signJwt(payload) {
  const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const sig = createHmac("sha256", secret).update(`${header}.${body}`).digest("base64url");
  return `${header}.${body}.${sig}`;
}

function verifyJwt(token) {
  const parts = String(token || "").split(".");
  if (parts.length !== 3) return null;
  const expected = createHmac("sha256", secret).update(`${parts[0]}.${parts[1]}`).digest("base64url");
  const actual = Buffer.from(parts[2]);
  const wanted = Buffer.from(expected);
  if (actual.length !== wanted.length || !timingSafeEqual(actual, wanted)) return null;
  const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString());
  if (payload.exp && payload.exp * 1000 < Date.now()) return null;
  return payload;
}

export function anonKey() {
  return signJwt({ role: "anon", iss: "itt-local", iat: 1700000000, exp: 2000000000 });
}

const refreshTokens = new Map();
let pool;

function publicUser(row) {
  const created = new Date(row.created_at).toISOString();
  const meta = row.raw_user_meta_data || {};
  return {
    id: row.id,
    aud: "authenticated",
    role: "authenticated",
    email: row.email,
    email_confirmed_at: created,
    phone: "",
    confirmed_at: created,
    last_sign_in_at: created,
    app_metadata: { provider: "email", providers: ["email"] },
    user_metadata: meta,
    identities: [{
      identity_id: row.id,
      id: row.id,
      user_id: row.id,
      identity_data: { email: row.email, sub: row.id },
      provider: "email",
      last_sign_in_at: created,
      created_at: created,
      updated_at: created
    }],
    created_at: created,
    updated_at: created,
    is_anonymous: false
  };
}

function sessionFor(row) {
  const expiresIn = 60 * 60 * 8;
  const now = Math.floor(Date.now() / 1000);
  const refresh = randomBytes(32).toString("hex");
  refreshTokens.set(refresh, row.id);
  return {
    access_token: signJwt({
      aud: "authenticated",
      role: "authenticated",
      sub: row.id,
      email: row.email,
      iat: now,
      exp: now + expiresIn
    }),
    token_type: "bearer",
    expires_in: expiresIn,
    expires_at: now + expiresIn,
    refresh_token: refresh,
    user: publicUser(row)
  };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function send(res, status, payload) {
  const body = payload === undefined || payload === null ? "" : JSON.stringify(payload);
  res.writeHead(status, {
    "content-type": "application/json",
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "*",
    "access-control-allow-methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
    "access-control-expose-headers": "content-range, content-type, preference-applied"
  });
  res.end(body);
}

async function findUser(where, value) {
  const result = await pool.query(
    `select id, email, raw_user_meta_data, created_at, encrypted_password
     from auth.users where ${where}`,
    [value]
  );
  return result.rows[0] || null;
}

async function handleAuth(req, res, url, raw) {
  let body = {};
  if (raw.length) {
    try {
      body = JSON.parse(raw.toString());
    } catch {
      send(res, 400, { msg: "Invalid JSON" });
      return;
    }
  }

  if (req.method === "POST" && url.pathname === "/auth/v1/signup") {
    const email = String(body.email || "").trim().toLowerCase();
    const password = String(body.password || "");
    if (!email.includes("@") || password.length < 8 || password.length > 72) {
      send(res, 400, { msg: "Password should be at least 8 characters", error_code: "weak_password" });
      return;
    }
    try {
      const inserted = await pool.query(
        `insert into auth.users (email, raw_user_meta_data, encrypted_password)
         values ($1, $2::jsonb, $3)
         returning id, email, raw_user_meta_data, created_at`,
        [email, JSON.stringify(body.data || {}), hashPassword(password)]
      );
      send(res, 200, sessionFor(inserted.rows[0]));
    } catch (error) {
      if (error.code === "23505") {
        send(res, 400, { msg: "User already registered", error_code: "user_already_exists" });
        return;
      }
      send(res, 400, { msg: error.message || "Registration failed" });
    }
    return;
  }

  if (req.method === "POST" && url.pathname === "/auth/v1/token") {
    const grant = url.searchParams.get("grant_type");
    if (grant === "password") {
      const email = String(body.email || "").trim().toLowerCase();
      const row = await findUser("lower(email) = lower($1)", email);
      if (!row || !verifyPassword(String(body.password || ""), row.encrypted_password)) {
        send(res, 400, { msg: "Invalid login credentials", error_code: "invalid_credentials" });
        return;
      }
      send(res, 200, sessionFor(row));
      return;
    }
    if (grant === "refresh_token") {
      const id = refreshTokens.get(body.refresh_token);
      if (!id) {
        send(res, 400, { msg: "Invalid Refresh Token" });
        return;
      }
      refreshTokens.delete(body.refresh_token);
      const row = await findUser("id = $1", id);
      if (!row) {
        send(res, 400, { msg: "Invalid Refresh Token" });
        return;
      }
      send(res, 200, sessionFor(row));
      return;
    }
    send(res, 400, { msg: "Unsupported grant" });
    return;
  }

  if (req.method === "GET" && url.pathname === "/auth/v1/user") {
    const token = String(req.headers.authorization || "").replace(/^Bearer\s+/i, "");
    const payload = verifyJwt(token);
    if (!payload || !payload.sub) {
      send(res, 401, { msg: "Invalid token" });
      return;
    }
    const row = await findUser("id = $1", payload.sub);
    if (!row) {
      send(res, 401, { msg: "Invalid token" });
      return;
    }
    send(res, 200, publicUser(row));
    return;
  }

  if (req.method === "POST" && url.pathname === "/auth/v1/logout") {
    res.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-headers": "*",
      "access-control-allow-methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    });
    res.end();
    return;
  }

  send(res, 404, { msg: "Not found" });
}

function proxyRest(req, res, url, raw) {
  const target = new URL(postgrestOrigin);
  const forwarded = http.request({
    hostname: target.hostname,
    port: target.port,
    method: req.method,
    path: url.pathname.replace(/^\/rest\/v1/, "") + url.search,
    headers: {
      ...req.headers,
      host: target.host
    }
  }, (upstream) => {
    const headers = { ...upstream.headers };
    delete headers["access-control-allow-origin"];
    delete headers["access-control-allow-headers"];
    delete headers["access-control-allow-methods"];
    headers["access-control-allow-origin"] = "*";
    headers["access-control-allow-headers"] = "*";
    headers["access-control-allow-methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS";
    headers["access-control-expose-headers"] = "content-range, content-type, preference-applied";
    res.writeHead(upstream.statusCode || 502, headers);
    upstream.pipe(res);
  });
  forwarded.on("error", () => {
    send(res, 502, { msg: "The diary database is not reachable" });
  });
  forwarded.end(raw);
}

async function main() {
  pool = new pg.Pool({ connectionString: databaseUrl });
  const server = http.createServer(async (req, res) => {
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-headers": "*",
      "access-control-allow-methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
      "access-control-max-age": "600"
    });
    res.end();
    return;
  }
  try {
    const url = new URL(req.url, `http://127.0.0.1:${port}`);
    const raw = await readBody(req);
    if (url.pathname.startsWith("/auth/v1/")) {
      await handleAuth(req, res, url, raw);
      return;
    }
    if (url.pathname.startsWith("/rest/v1/")) {
      proxyRest(req, res, url, raw);
      return;
    }
    send(res, 404, { msg: "Not found" });
  } catch (error) {
    send(res, 500, { msg: error.message || "Local gateway error" });
  }
  });

  server.listen(port, "127.0.0.1", () => {
    console.log(`ITT local gateway http://127.0.0.1:${port}`);
    console.log(`anon key ${anonKey()}`);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}

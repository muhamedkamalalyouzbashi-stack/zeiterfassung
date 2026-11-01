// Mitarbeiter anlegen, PIN ändern, Konto sperren. Nur hier ist der service_role Key verfügbar,
// deshalb prüft diese Funktion selbst, ob der Aufrufer Admin ist.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const EMAIL_DOMAIN = "intern.local";
const BAN_FOREVER = "876000h";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

const validPin = (pin: unknown) => typeof pin === "string" && /^\d{6}$/.test(pin);

const cleanUsername = (value: unknown) => {
  const username = String(value ?? "").trim().toLowerCase();
  return /^[a-z0-9._-]+$/.test(username) ? username : null;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer /, "");
  const { data: { user } } = await admin.auth.getUser(token);
  if (!user) return reply(401, { error: "not_signed_in" });

  const { data: caller } = await admin.from("mitarbeiter")
    .select("ist_admin").eq("user_id", user.id).maybeSingle();
  if (!caller?.ist_admin) return reply(403, { error: "not_admin" });

  const body = await req.json().catch(() => ({}));

  if (body.action === "anlegen") {
    const username = cleanUsername(body.benutzername);
    if (!username) return reply(400, { error: "invalid_username" });
    if (!validPin(body.pin)) return reply(400, { error: "invalid_pin" });

    const { error } = await admin.auth.admin.createUser({
      email: username + "@" + EMAIL_DOMAIN,
      password: body.pin,
      email_confirm: true,
    });
    if (error?.code === "email_exists") return reply(409, { error: "username_taken" });
    if (error) return reply(500, { error: "failed" });
    return reply(200, { ok: true });
  }

  // Alle weiteren Aktionen betreffen ein vorhandenes Konto. Admin-Konten bleiben hier tabu,
  // damit sich niemand versehentlich aussperrt.
  const { data: target } = await admin.from("mitarbeiter")
    .select("ist_admin, benutzername").eq("user_id", String(body.user_id ?? "")).maybeSingle();
  if (!target || target.ist_admin) return reply(400, { error: "invalid_target" });

  if (body.action === "umbenennen") {
    const username = cleanUsername(body.benutzername);
    if (!username) return reply(400, { error: "invalid_username" });
    const { error } = await admin.auth.admin.updateUserById(body.user_id, {
      email: username + "@" + EMAIL_DOMAIN,
      email_confirm: true,
    });
    if (error?.code === "email_exists") return reply(409, { error: "username_taken" });
    if (error) return reply(500, { error: "failed" });
    const { error: nameError } = await admin.from("mitarbeiter")
      .update({ benutzername: username }).eq("user_id", body.user_id);
    if (!nameError) return reply(200, { ok: true });
    // Anmeldename und angezeigter Name müssen gleich bleiben, also die E-Mail zurückdrehen.
    await admin.auth.admin.updateUserById(body.user_id, {
      email: target.benutzername + "@" + EMAIL_DOMAIN,
      email_confirm: true,
    });
    return nameError.code === "23505"
      ? reply(409, { error: "username_taken" })
      : reply(500, { error: "failed" });
  }

  if (body.action === "pin") {
    if (!validPin(body.pin)) return reply(400, { error: "invalid_pin" });
    const { error } = await admin.auth.admin.updateUserById(body.user_id, { password: body.pin });
    return error ? reply(500, { error: "failed" }) : reply(200, { ok: true });
  }

  if (body.action === "aktiv") {
    const aktiv = body.aktiv === true;
    const { error } = await admin.auth.admin.updateUserById(body.user_id, {
      ban_duration: aktiv ? "none" : BAN_FOREVER,
    });
    if (error) return reply(500, { error: "failed" });
    const { error: flagError } = await admin.from("mitarbeiter")
      .update({ aktiv }).eq("user_id", body.user_id);
    return flagError ? reply(500, { error: "failed" }) : reply(200, { ok: true });
  }

  return reply(400, { error: "unknown_action" });
});

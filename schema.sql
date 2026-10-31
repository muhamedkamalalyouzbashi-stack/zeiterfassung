-- Zeiterfassung: einmal komplett im Supabase SQL-Editor ausführen.
-- Stempelzeiten kommen vom Server, damit eine verstellte Geräteuhr sie nicht fälschen kann.

-- ============ Serverzeit (Zeitzone nur hier ändern) ============
create function public.zeiten_jetzt()
returns timestamp
language sql stable
set search_path = ''
as $$ select now() at time zone 'Europe/Berlin' $$;

-- ============ Tabellen ============
create table public.mitarbeiter (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  benutzername text not null unique,
  monatsgehalt numeric(10, 2) check (monatsgehalt >= 0),
  ist_admin    boolean not null default false,
  aktiv        boolean not null default true
);

-- Bezahlte Abwesenheit: zählt wie ein voller Arbeitstag.
create table public.abwesenheiten (
  id      bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id),
  datum   date not null,
  art     text not null check (art in ('urlaub', 'krank', 'feiertag')),
  unique (user_id, datum)
);

create table public.zeiten (
  id          bigint generated always as identity primary key,
  -- Kein "on delete cascade": Löschen eines Nutzers darf keine Lohndaten vernichten.
  user_id     uuid not null references auth.users (id),
  datum       date not null default public.zeiten_jetzt()::date,
  start_zeit  time(0) not null default public.zeiten_jetzt()::time(0),
  ende_zeit   time(0),
  erstellt_am timestamptz not null default now(),
  unique (user_id, datum)
);

-- ============ Hilfsfunktionen und Trigger ============
-- security definer, damit die mitarbeiter-Policies sich nicht selbst rekursiv abfragen.
create function public.ist_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce(
    (select ist_admin from public.mitarbeiter where user_id = auth.uid()),
    false
  )
$$;

-- Jeder neue Auth-Nutzer bekommt automatisch einen mitarbeiter-Eintrag.
create function public.mitarbeiter_anlegen()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.mitarbeiter (user_id, benutzername)
  values (new.id, lower(split_part(new.email, '@', 1)))
  on conflict do nothing;
  return new;
end
$$;

create trigger mitarbeiter_anlegen
after insert on auth.users
for each row execute function public.mitarbeiter_anlegen();

-- Bereits vorhandene Nutzer übernehmen.
insert into public.mitarbeiter (user_id, benutzername)
select id, lower(split_part(email, '@', 1)) from auth.users
on conflict do nothing;

-- "Gehen" setzt immer die Serverzeit, egal welchen Wert der Client schickt.
-- Änderungen im SQL-Editor oder Table Editor (Korrekturen) bleiben davon unberührt.
create function public.zeiten_ende_setzen()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.ende_zeit := public.zeiten_jetzt()::time(0);
  return new;
end
$$;

create trigger zeiten_ende_setzen
before update on public.zeiten
for each row
when (current_user = 'authenticated')
execute function public.zeiten_ende_setzen();

-- Admin-Korrekturen laufen über diese Funktionen, weil die Spaltenrechte unten
-- für alle eingeloggten Nutzer gleich gelten. security definer umgeht auch den Stempel-Trigger.
create function public.admin_zeit_speichern(
  p_id bigint,
  p_user_id uuid,
  p_datum date,
  p_start time,
  p_ende time
)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not public.ist_admin() then
    raise exception 'nicht erlaubt' using errcode = '42501';
  end if;
  if p_ende is not null and p_ende <= p_start then
    raise exception 'ende vor start' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.zeiten (user_id, datum, start_zeit, ende_zeit)
    values (p_user_id, p_datum, p_start, p_ende);
  else
    update public.zeiten
    set datum = p_datum, start_zeit = p_start, ende_zeit = p_ende
    where id = p_id;
  end if;
end
$$;

create function public.admin_zeit_loeschen(p_id bigint)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not public.ist_admin() then
    raise exception 'nicht erlaubt' using errcode = '42501';
  end if;
  delete from public.zeiten where id = p_id;
end
$$;

-- ============ Rechte: nur diese Spalten dürfen über die API geschrieben werden ============
revoke all on public.zeiten, public.mitarbeiter, public.abwesenheiten from anon, authenticated;

grant select on public.abwesenheiten to authenticated;
grant insert (user_id, datum, art) on public.abwesenheiten to authenticated;
grant delete on public.abwesenheiten to authenticated;

-- Für die Edge Function admin-mitarbeiter.
grant all on public.mitarbeiter to service_role;

revoke execute on function public.admin_zeit_speichern(bigint, uuid, date, time, time) from public, anon;
revoke execute on function public.admin_zeit_loeschen(bigint) from public, anon;
grant execute on function public.admin_zeit_speichern(bigint, uuid, date, time, time) to authenticated;
grant execute on function public.admin_zeit_loeschen(bigint) to authenticated;

grant select on public.zeiten to authenticated;
grant insert (user_id) on public.zeiten to authenticated;
grant update (ende_zeit) on public.zeiten to authenticated;

grant select on public.mitarbeiter to authenticated;
grant update (monatsgehalt) on public.mitarbeiter to authenticated;

revoke execute on function public.mitarbeiter_anlegen() from public, anon, authenticated;
revoke execute on function public.zeiten_ende_setzen() from public, anon, authenticated;

-- ============ Row-Level Security ============
alter table public.zeiten enable row level security;
alter table public.mitarbeiter enable row level security;
alter table public.abwesenheiten enable row level security;

create policy abwesenheiten_select on public.abwesenheiten
for select to authenticated
using ((select auth.uid()) = user_id or (select public.ist_admin()));

create policy abwesenheiten_insert on public.abwesenheiten
for insert to authenticated
with check ((select public.ist_admin()));

create policy abwesenheiten_delete on public.abwesenheiten
for delete to authenticated
using ((select public.ist_admin()));

create policy zeiten_select on public.zeiten
for select to authenticated
using ((select auth.uid()) = user_id or (select public.ist_admin()));

create policy zeiten_insert on public.zeiten
for insert to authenticated
with check ((select auth.uid()) = user_id);

-- Nur der eigene, noch offene Eintrag von heute kann beendet werden.
create policy zeiten_update on public.zeiten
for update to authenticated
using (
  (select auth.uid()) = user_id
  and ende_zeit is null
  and datum = public.zeiten_jetzt()::date
)
with check ((select auth.uid()) = user_id);

create policy mitarbeiter_select on public.mitarbeiter
for select to authenticated
using ((select auth.uid()) = user_id or (select public.ist_admin()));

create policy mitarbeiter_update on public.mitarbeiter
for update to authenticated
using ((select public.ist_admin()))
with check ((select public.ist_admin()));

-- ============ Admin festlegen (erst ausführen, nachdem der Nutzer angelegt wurde) ============
-- update public.mitarbeiter set ist_admin = true where benutzername = 'admin';

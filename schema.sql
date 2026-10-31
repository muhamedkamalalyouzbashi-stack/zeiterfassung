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
  ist_admin    boolean not null default false
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

-- ============ Rechte: nur diese Spalten dürfen über die API geschrieben werden ============
revoke all on public.zeiten, public.mitarbeiter from anon, authenticated;

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

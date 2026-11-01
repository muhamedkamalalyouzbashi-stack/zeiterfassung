-- Zeiterfassung, Update 2: Anmeldeorte und tägliche Notizen.
-- Einmal im Supabase SQL-Editor ausführen, nachdem schema.sql bereits gelaufen ist.

-- ============ Anmeldeorte: nur anhängen, nur der Admin liest ============
create table public.anmeldungen (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users (id),
  datum       date not null default public.zeiten_jetzt()::date,
  zeit        timestamptz not null default now(),
  status      text not null check (status in ('ok', 'abgelehnt', 'nicht_verfuegbar')),
  breite      double precision check (breite between -90 and 90),
  laenge      double precision check (laenge between -180 and 180),
  genauigkeit integer check (genauigkeit >= 0)
);

-- ============ Tägliche Notizen mit Checkliste ============
create table public.notizen (
  id       bigint generated always as identity primary key,
  user_id  uuid not null references auth.users (id),
  datum    date not null,
  inhalt   text not null default '' check (length(inhalt) <= 5000),
  aufgaben jsonb not null default '[]' check (
    jsonb_typeof(aufgaben) = 'array' and jsonb_array_length(aufgaben) <= 100
  ),
  unique (user_id, datum)
);

-- ============ Rechte ============
revoke all on public.anmeldungen, public.notizen from anon, authenticated;

grant select on public.anmeldungen to authenticated;
grant insert (user_id, status, breite, laenge, genauigkeit) on public.anmeldungen to authenticated;

grant select on public.notizen to authenticated;
grant insert (user_id, datum, inhalt, aufgaben) on public.notizen to authenticated;
grant update (user_id, datum, inhalt, aufgaben) on public.notizen to authenticated;

-- ============ Row-Level Security ============
alter table public.anmeldungen enable row level security;
alter table public.notizen enable row level security;

create policy anmeldungen_select on public.anmeldungen
for select to authenticated
using ((select public.ist_admin()));

create policy anmeldungen_insert on public.anmeldungen
for insert to authenticated
with check ((select auth.uid()) = user_id);

create policy notizen_select on public.notizen
for select to authenticated
using ((select auth.uid()) = user_id or (select public.ist_admin()));

-- Nur die eigene Notiz von heute kann geschrieben werden.
create policy notizen_insert on public.notizen
for insert to authenticated
with check ((select auth.uid()) = user_id and datum = public.zeiten_jetzt()::date);

create policy notizen_update on public.notizen
for update to authenticated
using ((select auth.uid()) = user_id and datum = public.zeiten_jetzt()::date)
with check ((select auth.uid()) = user_id and datum = public.zeiten_jetzt()::date);

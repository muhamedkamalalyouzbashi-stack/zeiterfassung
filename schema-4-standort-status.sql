-- Zeiterfassung, Update 4: Anmeldeorte unterscheiden "Zeit abgelaufen" von "nicht verfügbar".
-- Einmal im Supabase SQL-Editor ausführen, BEVOR die neue index.html online geht,
-- sonst scheitert das Speichern von 'zeit_abgelaufen' und der Eintrag fehlt.

alter table public.anmeldungen drop constraint anmeldungen_status_check;
alter table public.anmeldungen add constraint anmeldungen_status_check
  check (status in ('ok', 'abgelehnt', 'nicht_verfuegbar', 'zeit_abgelaufen'));

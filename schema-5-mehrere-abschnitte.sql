-- Zeiterfassung, Update 5: mehrere Arbeitsabschnitte pro Tag, zum Beispiel 8 bis 10 und 12 bis 17.
-- Einmal im Supabase SQL-Editor ausführen, BEVOR die neue index.html online geht.

alter table public.zeiten drop constraint zeiten_user_id_datum_key;

-- Pro Tag bleibt höchstens ein Abschnitt offen: erst ausstempeln, dann wieder einstempeln.
create unique index zeiten_ein_offener_abschnitt
  on public.zeiten (user_id, datum)
  where ende_zeit is null;

-- Überschneidungen würden Stunden doppelt bezahlen. Ein offener Abschnitt zählt bis Tagesende.
create or replace function public.admin_zeit_speichern(
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
  if exists (
    select 1 from public.zeiten
    where user_id = p_user_id
      and datum = p_datum
      and id is distinct from p_id
      and p_start < coalesce(ende_zeit, '24:00')
      and start_zeit < coalesce(p_ende, '24:00')
  ) then
    raise exception 'ueberschneidung' using errcode = '23505';
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

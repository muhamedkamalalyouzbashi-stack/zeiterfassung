-- Zeiterfassung, Update 3: Admin löscht einen Mitarbeiter endgültig.
-- Einmal im Supabase SQL-Editor ausführen, nachdem schema.sql und schema-2 bereits gelaufen sind.

-- Die Fremdschlüssel haben bewusst kein "on delete cascade", damit Löschen im Dashboard keine
-- Lohndaten vernichtet. Hier geschieht es ausdrücklich und in einer Transaktion: alles oder nichts.
create function public.admin_mitarbeiter_loeschen(p_user_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not public.ist_admin() then
    raise exception 'nicht erlaubt' using errcode = '42501';
  end if;
  -- Admin-Konten bleiben tabu, damit sich niemand aussperrt.
  if not exists (select 1 from public.mitarbeiter where user_id = p_user_id and not ist_admin) then
    raise exception 'ungueltiges Ziel' using errcode = '22023';
  end if;

  delete from public.zeiten where user_id = p_user_id;
  delete from public.abwesenheiten where user_id = p_user_id;
  delete from public.notizen where user_id = p_user_id;
  delete from public.anmeldungen where user_id = p_user_id;
  delete from auth.users where id = p_user_id;
end
$$;

revoke execute on function public.admin_mitarbeiter_loeschen(uuid) from public, anon;
grant execute on function public.admin_mitarbeiter_loeschen(uuid) to authenticated;

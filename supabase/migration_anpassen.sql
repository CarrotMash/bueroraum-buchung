-- =====================================================================
-- VAK Büro-Buchung: Höchstdauer 10,5 Std. und "Anpassen" eigener Buchungen
--   * Eigene Buchungen dürfen in Beginn/Ende geändert werden
--     (Platz, Datum und Person bleiben fest)
--   * Überschneidungsprüfung läuft auch beim Ändern (bestehender Trigger
--     + EXCLUDE-Constraints; die geänderte Buchung selbst zählt nicht)
--   * Änderungen werden mit alter und neuer Zeit protokolliert
-- =====================================================================

begin;

-- 1) Höchstdauer 10 Stunden 30 Minuten
alter table public.bookings drop constraint bookings_max_duration;
alter table public.bookings
  add constraint bookings_max_duration check (end_time - start_time <= interval '10 hours 30 minutes');

-- 2) Nur Beginn/Ende dürfen sich ändern
create or replace function public.prevent_booking_move()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if new.user_id is distinct from old.user_id
     or new.workspace_id is distinct from old.workspace_id
     or new.room_number is distinct from old.room_number
     or new.booking_date is distinct from old.booking_date then
    raise exception 'Beim Anpassen können nur Beginn und Ende geändert werden. Für einen anderen Platz oder Tag bitte stornieren und neu buchen.' using errcode = 'P0001';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_prevent_booking_move on public.bookings;
create trigger trg_prevent_booking_move
  before update on public.bookings
  for each row execute function public.prevent_booking_move();

-- 3) Berechtigung: eigene Buchungen ändern
drop policy if exists bookings_update_own on public.bookings;
create policy bookings_update_own on public.bookings
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- 4) Protokoll: Aktion "changed" mit vorheriger Zeit
alter table public.booking_log drop constraint booking_log_action_check;
alter table public.booking_log
  add constraint booking_log_action_check check (action = any (array['created'::text, 'cancelled'::text, 'changed'::text]));
alter table public.booking_log
  add column prev_start_time time,
  add column prev_end_time   time;

create or replace function public.log_booking_changed()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  owner_id uuid;
  actor_id uuid;
begin
  select id into owner_id from public.profiles where id = new.user_id;
  select id into actor_id from public.profiles where id = auth.uid();
  insert into public.booking_log (booking_id, action, user_id, acted_by, room_number, workspace_id, booking_date,
                                  start_time, end_time, prev_start_time, prev_end_time)
  values (new.id, 'changed', owner_id, actor_id, new.room_number, new.workspace_id, new.booking_date,
          new.start_time, new.end_time, old.start_time, old.end_time);
  return new;
end;
$function$;

drop trigger if exists trg_log_booking_changed on public.bookings;
create trigger trg_log_booking_changed
  after update on public.bookings
  for each row
  when (old.start_time is distinct from new.start_time or old.end_time is distinct from new.end_time)
  execute function public.log_booking_changed();

commit;

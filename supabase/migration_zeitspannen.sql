-- =====================================================================
-- VAK Büro-Buchung: Umstellung auf frei wählbare Zeitspannen
-- (statt Vormittag / Nachmittag / Ganztags)
--
-- Regeln:
--   * Buchbar zwischen 05:00 und 20:00 Uhr im 30-Minuten-Raster
--   * Höchstdauer 10 Stunden, Ende nach Beginn
--   * Ein Arbeitsplatz kann zu keinem Zeitpunkt doppelt belegt sein
--   * Eine Person kann zu keinem Zeitpunkt zwei Buchungen haben
--     (mehrere, sich nicht überschneidende Buchungen am Tag sind erlaubt)
--   * Angrenzende Zeiten (z. B. 08–12 und 12–16 Uhr) überschneiden sich nicht
--
-- Die Überschneidungsfreiheit wird doppelt gesichert:
--   1. Trigger mit verständlichen Fehlermeldungen
--   2. EXCLUDE-Constraints als harte Garantie, auch bei gleichzeitigen Klicks
--
-- Altbuchungen (nur Testdaten): AM = 08–12, PM = 12–16, FULL = 08–16 Uhr
-- =====================================================================

begin;

set local search_path = public, extensions;

create extension if not exists btree_gist with schema extensions;

-- ---------------------------------------------------------------------
-- 1) bookings: Uhrzeiten statt Tagesteil
-- ---------------------------------------------------------------------
alter table public.bookings
  add column start_time time,
  add column end_time   time;

update public.bookings set
  start_time = case part when 'PM' then time '12:00' else time '08:00' end,
  end_time   = case part when 'AM' then time '12:00' else time '16:00' end;

alter table public.bookings
  alter column start_time set not null,
  alter column end_time   set not null;

alter table public.bookings
  add constraint bookings_time_order   check (start_time < end_time),
  add constraint bookings_time_frame   check (start_time >= time '05:00' and end_time <= time '20:00'),
  add constraint bookings_time_grid    check (
        extract(second from start_time) = 0 and extract(second from end_time) = 0
    and extract(minute from start_time) in (0, 30)
    and extract(minute from end_time)   in (0, 30)),
  add constraint bookings_max_duration check (end_time - start_time <= interval '10 hours');

-- Zeitbereich als halboffenes Intervall [Beginn, Ende)
alter table public.bookings
  add column slot tsrange
  generated always as (tsrange(booking_date + start_time, booking_date + end_time, '[)')) stored;

-- Harte Garantie gegen Doppelbelegung / Doppelbuchung
alter table public.bookings
  add constraint bookings_no_workspace_overlap exclude using gist (workspace_id with =, slot with &&),
  add constraint bookings_no_user_overlap      exclude using gist (user_id      with =, slot with &&);

-- Tagesteil-Spalte entfällt
alter table public.bookings drop constraint if exists bookings_part_check;
alter table public.bookings drop column part;

-- ---------------------------------------------------------------------
-- 2) booking_log: Uhrzeiten protokollieren (Altprotokoll wird umgerechnet)
-- ---------------------------------------------------------------------
alter table public.booking_log
  add column start_time time,
  add column end_time   time,
  alter column part drop not null;

update public.booking_log set
  start_time = case part when 'PM' then time '12:00' else time '08:00' end,
  end_time   = case part when 'AM' then time '12:00' else time '16:00' end
where part is not null;

create or replace function public.log_booking_created()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  insert into public.booking_log (booking_id, action, user_id, acted_by, room_number, workspace_id, booking_date, start_time, end_time)
  values (new.id, 'created', new.user_id, auth.uid(), new.room_number, new.workspace_id, new.booking_date, new.start_time, new.end_time);
  return new;
end;
$function$;

create or replace function public.log_booking_cancelled()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  insert into public.booking_log (booking_id, action, user_id, acted_by, room_number, workspace_id, booking_date, start_time, end_time)
  values (old.id, 'cancelled', old.user_id, auth.uid(), old.room_number, old.workspace_id, old.booking_date, old.start_time, old.end_time);
  return old;
end;
$function$;

-- ---------------------------------------------------------------------
-- 3) Prüf-Trigger: verständliche Meldungen für alle Regeln
-- ---------------------------------------------------------------------
create or replace function public.prevent_overlapping_user_bookings()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  new_slot     tsrange;
  hit          record;
  perm_ws_id   text;
  perm_owner   uuid;
  on_vacation  boolean;
  user_group   uuid;
  ws_group     uuid;
  user_active  boolean;
begin
  select is_active into user_active from public.profiles where id = new.user_id;
  if user_active is false then
    raise exception 'Dieses Konto ist deaktiviert und kann keine Arbeitsplätze mehr buchen.' using errcode = 'P0001';
  end if;

  select exists(
    select 1 from public.vacations v
    where v.user_id = new.user_id and v.vacation_date = new.booking_date
  ) into on_vacation;
  if on_vacation then
    raise exception 'An deinem eingetragenen Urlaubstag können keine Arbeitsplätze gebucht werden.' using errcode = 'P0001';
  end if;

  if new.end_time <= new.start_time then
    raise exception 'Das Ende muss nach dem Beginn liegen.' using errcode = 'P0001';
  end if;

  new_slot := tsrange(new.booking_date + new.start_time, new.booking_date + new.end_time, '[)');

  -- eigene Doppelbuchung
  select b.start_time, b.end_time, b.room_number into hit
  from public.bookings b
  where b.user_id = new.user_id and b.id <> new.id and b.slot && new_slot
  order by b.start_time limit 1;
  if found then
    raise exception 'Du hast von % bis % Uhr bereits eine andere Buchung (Raum %). Zeiträume dürfen sich nicht überschneiden.',
      to_char(hit.start_time, 'HH24:MI'), to_char(hit.end_time, 'HH24:MI'), hit.room_number using errcode = 'P0001';
  end if;

  -- Doppelbelegung des Arbeitsplatzes
  select b.start_time, b.end_time into hit
  from public.bookings b
  where b.workspace_id = new.workspace_id and b.id <> new.id and b.slot && new_slot
  order by b.start_time limit 1;
  if found then
    raise exception 'Dieser Arbeitsplatz ist von % bis % Uhr bereits belegt. Bitte einen anderen Zeitraum wählen.',
      to_char(hit.start_time, 'HH24:MI'), to_char(hit.end_time, 'HH24:MI') using errcode = 'P0001';
  end if;

  -- eigener fester Arbeitsplatz
  select workspace_id into perm_ws_id from public.permanent_assignments where user_id = new.user_id limit 1;
  if perm_ws_id is not null and perm_ws_id <> new.workspace_id then
    raise exception 'Dir ist bereits ein fester Büroarbeitsplatz dauerhaft zugewiesen. Andere Arbeitsplätze können daher nicht gebucht werden.' using errcode = 'P0001';
  end if;

  -- fremder fester Arbeitsplatz (nur buchbar, wenn die Inhaberin / der Inhaber an dem Tag Urlaub hat)
  select user_id into perm_owner from public.permanent_assignments where workspace_id = new.workspace_id;
  if perm_owner is not null and perm_owner <> new.user_id and not exists (
       select 1 from public.vacations v where v.user_id = perm_owner and v.vacation_date = new.booking_date) then
    raise exception 'Dieser Arbeitsplatz ist dauerhaft vergeben und an diesem Tag nicht freigegeben.' using errcode = 'P0001';
  end if;

  -- Gruppenzugehörigkeit
  select group_id into user_group from public.profiles where id = new.user_id;
  if user_group is null then
    raise exception 'Dir ist noch keine Gruppe zugewiesen. Bitte wende dich an eine Systemverwaltung.' using errcode = 'P0001';
  end if;

  select r.group_id into ws_group
  from public.workspaces w join public.rooms r on r.id = w.room_id
  where w.id = new.workspace_id;
  if ws_group is null or ws_group is distinct from user_group then
    raise exception 'Dieser Arbeitsplatz gehört nicht zu deiner Gruppe und kann daher nicht gebucht werden.' using errcode = 'P0001';
  end if;

  return new;
end;
$function$;

-- Trigger zusätzlich bei Änderungen ausführen (bisher nur beim Anlegen)
drop trigger if exists trg_prevent_overlapping_bookings on public.bookings;
create trigger trg_prevent_overlapping_bookings
  before insert or update of user_id, workspace_id, booking_date, start_time, end_time
  on public.bookings for each row execute function public.prevent_overlapping_user_bookings();

commit;

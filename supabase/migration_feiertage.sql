-- =====================================================================
-- VAK Büro-Buchung: Feiertage Schleswig-Holstein
--
-- Rechtsgrundlage: § 2 Abs. 1 Gesetz über Sonn- und Feiertage (SFTG SH)
--   Neujahr (1.1.), Karfreitag, Ostermontag, 1. Mai, Christi Himmelfahrt,
--   Pfingstmontag, Tag der Deutschen Einheit (3.10.), Reformationstag
--   (31.10., seit 2018), 1. und 2. Weihnachtstag (25./26.12.)
-- Bewegliche Feiertage werden aus dem Osterdatum berechnet (Gauß/
-- Meeus-Jones-Butcher, gregorianischer Kalender).
-- Einmalige Feiertage nach § 2 Abs. 2 (Verordnung der Landesregierung)
-- pflegen Admins in der Tabelle holidays_extra (Systemverwaltung).
--
-- An Feiertagen und Wochenenden sind keine Buchungen möglich.
-- =====================================================================

begin;

-- 1) Ostersonntag
create or replace function public.easter_sunday(y int)
returns date language plpgsql immutable as $function$
declare a int; b int; c int; d int; e int; f int; g int; h int; i int; k int; l int; m int; mon int; dy int;
begin
  a := y % 19; b := y / 100; c := y % 100; d := b / 4; e := b % 4;
  f := (b + 8) / 25; g := (b - f + 1) / 3;
  h := (19 * a + b - d - g + 15) % 30;
  i := c / 4; k := c % 4;
  l := (32 + 2 * e + 2 * i - h - k) % 7;
  m := (a + 11 * h + 22 * l) / 451;
  mon := (h + l - 7 * m + 114) / 31;
  dy := ((h + l - 7 * m + 114) % 31) + 1;
  return make_date(y, mon, dy);
end;
$function$;

-- 2) Zusätzliche (einmalige) Feiertage
create table if not exists public.holidays_extra (
  holiday_date date primary key,
  name text not null check (length(trim(name)) > 0),
  created_at timestamptz not null default now()
);
alter table public.holidays_extra enable row level security;
drop policy if exists holidays_extra_select on public.holidays_extra;
create policy holidays_extra_select on public.holidays_extra for select to anon, authenticated using (true);
drop policy if exists holidays_extra_admin_write on public.holidays_extra;
create policy holidays_extra_admin_write on public.holidays_extra for all to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

-- 3) Name des Feiertags (oder null)
create or replace function public.sh_holiday_name(d date)
returns text language plpgsql stable set search_path to 'public' as $function$
declare y int := extract(year from d)::int; es date; extra text;
begin
  es := public.easter_sunday(y);
  if d = make_date(y, 1, 1)   then return 'Neujahr'; end if;
  if d = es - 2               then return 'Karfreitag'; end if;
  if d = es + 1               then return 'Ostermontag'; end if;
  if d = make_date(y, 5, 1)   then return 'Tag der Arbeit'; end if;
  if d = es + 39              then return 'Christi Himmelfahrt'; end if;
  if d = es + 50              then return 'Pfingstmontag'; end if;
  if d = make_date(y, 10, 3)  then return 'Tag der Deutschen Einheit'; end if;
  if d = make_date(y, 10, 31) and y >= 2018 then return 'Reformationstag'; end if;
  if d = make_date(y, 12, 25) then return '1. Weihnachtstag'; end if;
  if d = make_date(y, 12, 26) then return '2. Weihnachtstag'; end if;
  select name into extra from public.holidays_extra where holiday_date = d;
  return extra;
end;
$function$;

-- 4) Prüf-Trigger um Wochenende/Feiertag ergänzen (übrige Regeln unverändert)
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
  hol          text;
begin
  select is_active into user_active from public.profiles where id = new.user_id;
  if user_active is false then
    raise exception 'Dieses Konto ist deaktiviert und kann keine Arbeitsplätze mehr buchen.' using errcode = 'P0001';
  end if;

  if extract(isodow from new.booking_date) in (6, 7) then
    raise exception 'An Wochenenden können keine Arbeitsplätze gebucht werden.' using errcode = 'P0001';
  end if;
  hol := public.sh_holiday_name(new.booking_date);
  if hol is not null then
    raise exception 'Am % (%) ist Feiertag – Buchungen sind nicht möglich.', to_char(new.booking_date, 'DD.MM.YYYY'), hol using errcode = 'P0001';
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

  select b.start_time, b.end_time, b.room_number into hit
  from public.bookings b
  where b.user_id = new.user_id and b.id <> new.id and b.slot && new_slot
  order by b.start_time limit 1;
  if found then
    raise exception 'Du hast von % bis % Uhr bereits eine andere Buchung (Raum %). Zeiträume dürfen sich nicht überschneiden.',
      to_char(hit.start_time, 'HH24:MI'), to_char(hit.end_time, 'HH24:MI'), hit.room_number using errcode = 'P0001';
  end if;

  select b.start_time, b.end_time into hit
  from public.bookings b
  where b.workspace_id = new.workspace_id and b.id <> new.id and b.slot && new_slot
  order by b.start_time limit 1;
  if found then
    raise exception 'Dieser Arbeitsplatz ist von % bis % Uhr bereits belegt. Bitte einen anderen Zeitraum wählen.',
      to_char(hit.start_time, 'HH24:MI'), to_char(hit.end_time, 'HH24:MI') using errcode = 'P0001';
  end if;

  select workspace_id into perm_ws_id from public.permanent_assignments where user_id = new.user_id limit 1;
  if perm_ws_id is not null and perm_ws_id <> new.workspace_id then
    raise exception 'Dir ist bereits ein fester Büroarbeitsplatz dauerhaft zugewiesen. Andere Arbeitsplätze können daher nicht gebucht werden.' using errcode = 'P0001';
  end if;

  select user_id into perm_owner from public.permanent_assignments where workspace_id = new.workspace_id;
  if perm_owner is not null and perm_owner <> new.user_id and not exists (
       select 1 from public.vacations v where v.user_id = perm_owner and v.vacation_date = new.booking_date) then
    raise exception 'Dieser Arbeitsplatz ist dauerhaft vergeben und an diesem Tag nicht freigegeben.' using errcode = 'P0001';
  end if;

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

commit;

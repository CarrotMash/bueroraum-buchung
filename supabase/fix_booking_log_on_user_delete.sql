-- Beim Löschen einer Person werden ihre Buchungen per Kaskade entfernt. Der Protokolleintrag
-- darf dann nicht mehr auf die (gerade gelöschte) Person verweisen, sonst scheitert das Löschen.
create or replace function public.log_booking_cancelled()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  owner_id uuid;
  actor_id uuid;
begin
  select id into owner_id from public.profiles where id = old.user_id;
  select id into actor_id from public.profiles where id = auth.uid();
  insert into public.booking_log (booking_id, action, user_id, acted_by, room_number, workspace_id, booking_date, start_time, end_time)
  values (old.id, 'cancelled', owner_id, actor_id, old.room_number, old.workspace_id, old.booking_date, old.start_time, old.end_time);
  return old;
end;
$function$;

-- =====================================================================
-- VAK Büro-Buchung: persönliche Lieblingszeit (Favorit) je Person
-- z. B. 07:00–16:00 Uhr; erscheint im Buchungsdialog als erste
-- Schnellauswahl und wird bevorzugt vorgeschlagen.
-- Änderbar über die bestehende Berechtigung "profiles_update_own".
-- =====================================================================

alter table public.profiles
  add column favorite_start time,
  add column favorite_end   time;

alter table public.profiles
  add constraint profiles_favorite_valid check (
    (favorite_start is null and favorite_end is null)
    or (
          favorite_start < favorite_end
      and favorite_start >= time '05:00' and favorite_end <= time '20:00'
      and extract(minute from favorite_start) in (0, 30) and extract(second from favorite_start) = 0
      and extract(minute from favorite_end)   in (0, 30) and extract(second from favorite_end)   = 0
      and favorite_end - favorite_start <= interval '10 hours 30 minutes'
    )
  );

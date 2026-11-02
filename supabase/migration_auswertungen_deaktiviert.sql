-- =====================================================================
-- VAK Büro-Buchung: Bereich "Auswertungen" deaktiviert
-- (datenschutzrechtliche Bedenken / Mitbestimmung des Personalrats)
--
-- Das Buchungsprotokoll (booking_log) ist damit für niemanden mehr über
-- die App-Schnittstelle lesbar – auch nicht für Admins. Ohne Lese-
-- Berechtigung greift die Zeilensicherheit (RLS) und liefert keine Daten.
--
-- Wieder einschalten (nach Freigabe):
--   create policy booking_log_select_admin on public.booking_log
--     for select using (exists (select 1 from public.profiles p
--                               where p.id = auth.uid() and p.is_admin));
--   und in index.html REPORTS_ENABLED = true setzen.
-- =====================================================================

drop policy if exists booking_log_select_admin on public.booking_log;

# Termini bot

Vsakih nekaj minut preveri proste termine za vožnjo (kat. B, Kranj) na
[e-Upravi](https://e-uprava.gov.si/si/javne-evidence/prosti-termini-zemljevid.html) in pošlje
obvestilo na telefon (aplikacija ntfy), ko se sprosti termin vsaj `MIN_DNI` dni pred mojim.

- Nastavitve (`MOJ_TERMIN`, `MIN_DNI`) so v `.github/workflows/termini.yml`.
- Tema za ntfy je v secretu `NTFY_TEMA` (Settings → Secrets and variables → Actions).
- Ročni zagon s testnim obvestilom: Actions → Termini bot → Run workflow.
- `stanje.json` si zapomni, kaj je bilo že javljeno; workflow ga posodablja sam.

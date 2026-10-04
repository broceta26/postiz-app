# Postiz na ofis-pc

Self-hosted Postiz na kancelarijskom računaru koji radi 24/7 (Windows + Docker Desktop).
Javna HTTPS adresa ide preko **Tailscale Funnel**, bez otvaranja portova na ruteru i bez izmene DNS-a.
HTTPS je obavezan: Meta i LinkedIn vraćaju korisnika posle prijave samo na HTTPS adresu, a Instagram preuzima slike sa adrese Postiz-a.

| Fajl | Šta radi |
|---|---|
| `install.ps1` | Instalira i ažurira. Može da se pokreće više puta i staje kad mora nešto da uradiš ti. |
| `docker-compose.yaml` | Postiz `v2.25.0` + Postgres + Redis + Temporal. Sve baze su na imenovanim volume-ima. |
| `watchdog.ps1` | Na svakih 5 min diže Postiz ako je pao i javlja na Telegram. Jednom dnevno pravi backup baze u `C:\postiz\backups` i čuva poslednjih 14. |
| `.env.example` | Šablon. Pravi `.env` sa tajnama postoji samo na ofis-pc i nikad ne ide u git. |

## Instalacija

PowerShell **kao administrator** na ofis-pc:

```powershell
irm https://raw.githubusercontent.com/broceta26/postiz-app/main/deploy/ofis-pc/install.ps1 -OutFile $env:TEMP\postiz-install.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\postiz-install.ps1
```

Skripta staje i piše `TVOJ KORAK` kad je potrebna tvoja prijava ili klik: Docker uslovi, prijava u Tailscale, uključivanje Funnel-a.
Kad to uradiš, pokreni ponovo: `powershell -ExecutionPolicy Bypass -File C:\postiz\install.ps1`.

Na kraju ispiše adresu, na primer `https://ofis-pc.tail1234.ts.net`. **Prvi nalog koji se registruje postaje admin** i posle njega je registracija zatvorena.

## Posle instalacije

1. Settings → Developers → kopiraj API ključ. Njime agent šalje odobrene pakete objava (`POST /api/public/v1/posts`).
2. Brendovi su grupe (customers) unutar jedne organizacije: `FX Doctor`, `SwissPrimeMarkets`, kasnije `DayProp`, `ShowMeTrade`. Pri povezivanju svakog kanala izaberi njegov brend.
3. Kanali: ključeve upiši u `C:\postiz\.env`, pa pokreni `install.ps1` ponovo.
   - **Telegram:** @BotFather → `/newbot` → `TELEGRAM_TOKEN` i `TELEGRAM_BOT_NAME`. Bota dodaj kao admina kanala, pa u Postiz-u Add Channel → Telegram.
   - **Facebook + Instagram:** jedna Meta aplikacija (developers.facebook.com → Business tip). Kao Valid OAuth Redirect URI upiši `https://<adresa>/integrations/social/facebook` i `https://<adresa>/integrations/social/instagram`. Upiši `FACEBOOK_APP_ID` i `FACEBOOK_APP_SECRET`. Dok si admin aplikacije, za svoje strane radi i bez Meta pregleda. Instagram mora biti Business nalog povezan sa FB stranom.
   - **LinkedIn stranice:** aplikacija na developer.linkedin.com, povezana sa stranom firme. Treba joj proizvod **Community Management API**, koji LinkedIn odobrava posle prijave, pa podnesi prijavu što pre. Redirect: `https://<adresa>/integrations/social/linkedin-page`.
4. `ALERT_CHAT_ID` u `.env`: tvoj Telegram chat id (piši botu, pa otvori `https://api.telegram.org/bot<TOKEN>/getUpdates`). Tu stižu poruke nadzora.

## Održavanje

- Logovi: `docker compose -f C:\postiz\docker-compose.yaml logs -f postiz`
- Log nadzora: `C:\postiz\watchdog.log`
- Nova verzija: promeni tag u `docker-compose.yaml` u repou, pa pokreni `install.ps1`. Ne koristi `latest`, da se ništa ne promeni dok si odsutan.
- Vraćanje backup-a: `docker cp C:\postiz\backups\postiz-YYYYMMDD.sql postiz-postgres:/tmp/r.sql`, pa `docker exec postiz-postgres psql -U postiz-user -d postiz-db -f /tmp/r.sql`

## Rizici dok niko nije u kancelariji

- **Restart posle Windows Update-a.** Docker Desktop radi tek kad se korisnik prijavi. Zato uključi automatsku prijavu (Sysinternals Autologon) ili pauziraj ažuriranja dok si na putu: Settings → Windows Update → Pause.
- **Nestanak struje ili interneta.** Zakazane objave čekaju i izlaze kad se računar vrati, a nadzor javlja na Telegram.
- **Disk.** Uz Postiz ide i Elasticsearch. Ako na disku ostane manje od ~1 GB, Temporal staje.

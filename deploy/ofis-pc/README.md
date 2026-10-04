# Postiz na ofis-pc

Self-hosted Postiz na kancelarijskom računaru koji radi 24/7 (Windows + Docker Desktop).
Javna HTTPS adresa ide preko **Tailscale Funnel**, bez otvaranja portova na ruteru i bez izmene DNS-a.
HTTPS je obavezan: Meta i LinkedIn vraćaju korisnika posle prijave samo na HTTPS adresu, a Instagram preuzima slike sa adrese Postiz-a.

| Fajl | Šta radi |
|---|---|
| `install.ps1` | Instalira i ažurira. Može da se pokreće više puta i staje kad mora nešto da uradiš ti. |
| `docker-compose.yaml` | Postiz `v2.25.0` + Postgres + Redis + Temporal. Sve baze su na imenovanim volume-ima. |
| `watchdog.ps1` | Na svakih 5 min diže Postiz ako je pao i javlja na Telegram. Jednom dnevno pravi backup baze u `C:\postiz\backups` i čuva poslednjih 14. |
| `schedule-batch.ps1` | Zakazuje odobren paket objava (JSON + slike) na kanale jednog brenda. Može da se pokreće više puta i ne pravi duplikate. |
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

Zašto `NOT_SECURED=true`: `ts.net` je javni sufiks, pa browser odbija kolačić za `.ts.net`. Sa ovim podešavanjem kolačić važi samo za tvoju adresu, a veza i dalje ide preko HTTPS-a.

## Posle instalacije

1. Settings → Developers → kopiraj API ključ. Njime agent šalje odobrene pakete objava (`POST /api/public/v1/posts`).
2. Brendovi su grupe (customers) unutar jedne organizacije: `FX Doctor`, `SwissPrimeMarkets`, kasnije `DayProp`, `ShowMeTrade`. Pri povezivanju svakog kanala izaberi njegov brend.
3. Kanali: ključeve upiši u `C:\postiz\.env`, pa pokreni `install.ps1` ponovo.
   - **Telegram:** @BotFather → `/newbot` → `TELEGRAM_TOKEN` i `TELEGRAM_BOT_NAME`. Bota dodaj kao admina kanala, pa u Postiz-u Add Channel → Telegram.
   - **Facebook + Instagram:** jedna Meta aplikacija (developers.facebook.com → Business tip). Kao Valid OAuth Redirect URI upiši `https://<adresa>/integrations/social/facebook` i `https://<adresa>/integrations/social/instagram`. Upiši `FACEBOOK_APP_ID` i `FACEBOOK_APP_SECRET`. Aplikaciju prebaci u **Live**, za šta treba URL politike privatnosti. U Development režimu objave vide samo nalozi sa ulogom u aplikaciji. Za tvoje strane je dovoljan standardni pristup, bez Meta pregleda, dok si admin aplikacije. Instagram mora biti Business nalog povezan sa FB stranom.
   - **LinkedIn stranice:** aplikacija na developer.linkedin.com, povezana sa stranom firme. Postiz traži sve ove dozvole: `openid profile w_member_social r_basicprofile rw_organization_admin w_organization_social r_organization_social`. Daju ih proizvodi **Sign In with LinkedIn using OpenID Connect**, **Share on LinkedIn** i **Community Management API**. Treći LinkedIn odobrava posle prijave, pa je podnesi što pre. Redirect: `https://<adresa>/integrations/social/linkedin-page`.
4. `ALERT_CHAT_ID` u `.env`: tvoj Telegram chat id (piši botu, pa otvori `https://api.telegram.org/bot<TOKEN>/getUpdates`). Tu stižu poruke nadzora.

## Zakazivanje odobrenog paketa

1. API ključ (Settings → Developers) upiši u `C:\postiz\.env` kao `POSTIZ_API_KEY=`.
2. Paket je JSON (`id`, `date`, `channels`, `text`), a slike su u folderu `kreative` pored njega, imenovane `<id>_01.jpg`, `<id>_02.jpg`...
3. Prvo proba, ništa se ne šalje: `powershell -ExecutionPolicy Bypass -File C:\postiz\schedule-batch.ps1 -Batch <paket.json> -Brand "FX Doctor" -DryRun`
4. Pa pravo: isti red bez `-DryRun`. Objave se pojave u Postiz kalendaru, u grupi tog brenda.

Kanal koji još nije povezan se preskače. Kad ga povežeš, pokreni isti red ponovo i dodaće se samo te objave. Ako objava za Instagram nema sliku, skripta ne zakazuje ni njenu Facebook verziju.

## Održavanje

- Logovi: `docker compose -f C:\postiz\docker-compose.yaml logs -f postiz`
- Log nadzora: `C:\postiz\watchdog.log`
- Nova verzija: promeni tag u `docker-compose.yaml` u repou, pa pokreni `install.ps1`. Ne koristi `latest`, da se ništa ne promeni dok si odsutan.
- Vraćanje backup-a (dump briše i ponovo pravi tabele): `docker stop postiz`, `docker cp C:\postiz\backups\postiz-YYYYMMDD.sql postiz-postgres:/tmp/r.sql`, `docker exec postiz-postgres psql -U postiz-user -d postiz-db -f /tmp/r.sql`, pa `docker start postiz`.

## Rizici dok niko nije u kancelariji

- **Restart posle Windows Update-a.** Docker Desktop radi tek kad se korisnik prijavi. Zato uključi automatsku prijavu (Sysinternals Autologon) ili pauziraj ažuriranja dok si na putu: Settings → Windows Update → Pause.
- **Nestanak struje ili interneta.** Zakazane objave čekaju i izlaze kad se računar vrati, a nadzor javlja na Telegram.
- **Disk.** Uz Postiz ide i Elasticsearch. Ako na disku ostane manje od ~1 GB, Temporal staje.

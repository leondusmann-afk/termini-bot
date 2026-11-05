# Spremlja proste termine za voznjo (kat. B, Kranj) na e-Upravi in poslje obvestilo
# na telefon (ntfy), ko se sprosti termin vsaj MIN_DNI dni pred tvojim.
#
# En zagon = en pregled. Na GitHubu ga Actions pozene vsakih nekaj minut, kaj je bilo
# ze javljeno pa si zapomni v stanje.json (workflow ga po zagonu shrani v repozitorij).
#
# Nastavitve (spremenljivke okolja):
#   MOJ_TERMIN  tvoj trenutni termin, npr. 2027-02-02
#   MIN_DNI     koliko dni prej mora biti termin, da ga javi
#   NTFY_TEMA   ntfy tema za obvestila (na GitHubu kot secret)
#   TEST        1 = poslji se testno obvestilo s trenutnim stanjem

$ErrorActionPreference = 'Stop'

function Nastavitev($ime, $privzeto) {
    $v = [Environment]::GetEnvironmentVariable($ime)
    if ([string]::IsNullOrWhiteSpace($v)) { $privzeto } else { $v.Trim() }
}

$MojTermin = [datetime]::ParseExact((Nastavitev 'MOJ_TERMIN' '2027-02-02'), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$MinDni    = [int](Nastavitev 'MIN_DNI' '7')
$NtfyTema  = Nastavitev 'NTFY_TEMA' ''
$Test      = (Nastavitev 'TEST' '') -in @('1', 'true')
# Javi termine na ta dan ali prej.
$Meja      = $MojTermin.AddDays(-$MinDni)
$StanjeDat = Join-Path $PSScriptRoot 'stanje.json'

# Filtri: kat. B, izpitni center 18, lokacija 223 (Kranj). page = teden od tega naprej.
$PodatkiUrl = 'https://e-uprava.gov.si/si/javne-evidence/prosti-termini-zemljevid/content/singleton.html' +
    '?lang=si&type=-&cat=6&izpitniCenter=18&lokacija=223&offset=0' +
    '&sentinel_type=ok&sentinel_status=ok&is_ajax=1&complete=false&page='
$StranUrl = 'https://e-uprava.gov.si/si/javne-evidence/prosti-termini-zemljevid.html?lang=si#eyJmaWx0ZXJzIjp7ImNhbGVuZGFyX2RhdGUiOiIiLCJpenBpdG5pQ2VudGVyIjoiMTgiLCJjYXQiOlsiNiJdLCJsb2thY2lqYSI6IjIyMyIsInR5cGUiOlsiLSJdfX0='

try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById('Europe/Ljubljana') }
catch { $tz = [TimeZoneInfo]::FindSystemTimeZoneById('Central European Standard Time') }
$zdaj  = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz)
$danes = $zdaj.Date

try { $slo = [Globalization.CultureInfo]::GetCultureInfo('sl-SI') }
catch { $slo = [Globalization.CultureInfo]::InvariantCulture }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$web = New-Object System.Net.WebClient
$web.Encoding = [System.Text.Encoding]::UTF8
$web.Headers['User-Agent'] = 'termini-bot (osebno obvescanje o prostih terminih)'

function Zapisi($sporocilo) {
    Write-Host ('[{0:dd.MM. HH:mm:ss}] {1}' -f $zdaj, $sporocilo)
}

function Opis($t) {
    '{0} ob {1} ({2} prosto, {3} dni prej)' -f $t.Datum.ToString('ddd d. M. yyyy', $slo), $t.Ura, $t.Prosta, ($MojTermin - $t.Datum).Days
}

function Poslji($naslov, $besedilo, $prioriteta, $oznake) {
    Zapisi "Obvestilo: $naslov`n$besedilo"
    if (-not $NtfyTema) { Zapisi '(NTFY_TEMA ni nastavljena, obvestilo ni poslano)'; return }
    # Glave morajo biti ASCII, besedilo gre kot UTF-8.
    Invoke-RestMethod -Method Post -Uri "https://ntfy.sh/$NtfyTema" -UseBasicParsing -Headers @{
        Title    = $naslov
        Priority = $prioriteta
        Tags     = $oznake
        Click    = $StranUrl
    } -Body ([System.Text.Encoding]::UTF8.GetBytes($besedilo)) | Out-Null
}

# Vrne vse termine iz enega tedna (ene strani).
function Preberi-Teden($html) {
    if ($html -notmatch 'js_resultsWeek') { throw 'Stran je vrnila nepricakovano vsebino (morda je spremenila obliko).' }
    $termini = @()
    $datum = $null
    # Vsak termin je svoja vrstica; datum je samo v prvi vrstici dneva.
    foreach ($kos in ($html -split '<tr class="js_dogodekBox') | Select-Object -Skip 1) {
        if ($kos -match 'calendarBox"[^>]*title="(\d+)\. (\d+)\. (\d{4})"') {
            $datum = Get-Date -Year $Matches[3] -Month $Matches[2] -Day $Matches[1] -Hour 0 -Minute 0 -Second 0 -Millisecond 0
        }
        if (-not $datum) { continue }
        $ura = if ($kos -match 'data-th="Ura">\s*(\d{1,2}:\d{2})') { $Matches[1] } else { '?' }
        $prosta = if ($kos -match 'data-th="Prosta mesta">\s*(\d+)') { [int]$Matches[1] } else { 0 }
        $kategorije = if ($kos -match '(?s)data-th="Kategorije">(.*?)</td>') { ($Matches[1] -replace '\s+', '') } else { '' }
        $termini += [pscustomobject]@{
            Datum      = $datum.Date
            Ura        = $ura
            Prosta     = $prosta
            Kategorije = $kategorije
            Voznja     = $kos -match 'Preverjanje znanja vo'
        }
    }
    $termini
}

# Pregleda tedne od tega do tistega, v katerem je meja (+1 za varnost).
function Poisci-Termine {
    $ponedeljek = $danes.AddDays(-(([int]$danes.DayOfWeek + 6) % 7))
    $tednov = [math]::Min(60, [math]::Floor(($Meja - $ponedeljek).TotalDays / 7) + 2)
    $vsi = @()
    for ($teden = 0; $teden -lt $tednov; $teden++) {
        $vsi += @(Preberi-Teden ($web.DownloadString($PodatkiUrl + $teden)))
        Start-Sleep -Milliseconds 800
    }
    # Ob isti uri je lahko vec izprasevalcev; zdruzi jih v en termin.
    @($vsi | Where-Object { $_.Voznja -and $_.Prosta -gt 0 -and $_.Kategorije -match '(^|,)B(,|$)' } |
        Group-Object { '{0} {1}' -f $_.Datum.ToString('yyyy-MM-dd'), $_.Ura } |
        ForEach-Object {
            [pscustomobject]@{
                Kljuc  = $_.Name
                Datum  = $_.Group[0].Datum
                Ura    = $_.Group[0].Ura
                Prosta = ($_.Group | Measure-Object Prosta -Sum).Sum
            }
        } | Sort-Object Kljuc)
}

# --- stanje prejsnjih zagonov ---
$stanje = $null
if (Test-Path $StanjeDat) {
    $vsebina = Get-Content $StanjeDat -Raw
    if ($vsebina) { $stanje = $vsebina | ConvertFrom-Json }
}
$javljeni      = @(if ($stanje -and $stanje.javljeni) { $stanje.javljeni })
$zadnjiZivSem  = if ($stanje -and $stanje.zadnjiZivSem) { [string]$stanje.zadnjiZivSem } else { '' }
$napakeZapored = if ($stanje -and $stanje.napakeZapored) { [int]$stanje.napakeZapored } else { 0 }

function Shrani-Stanje {
    [pscustomobject]@{
        javljeni      = @($javljeni)
        zadnjiZivSem  = $zadnjiZivSem
        napakeZapored = $napakeZapored
    } | ConvertTo-Json | Set-Content $StanjeDat -Encoding ASCII
}

if ($danes -gt $Meja) {
    Zapisi "Meja ($($Meja.ToString('d. M. yyyy'))) je ze mimo, nimam vec kaj iskati."
    exit 0
}

Zapisi ("Iscem termine za voznjo do {0:d. M. yyyy} (tvoj termin {1:d. M. yyyy}, vsaj {2} dni prej)." -f $Meja, $MojTermin, $MinDni)

try {
    $termini = Poisci-Termine
} catch {
    $napakeZapored++
    Zapisi "Napaka ($napakeZapored. zapored): $($_.Exception.Message)"
    # Ena napaka je lahko le motnja na strani; po treh zapored te opozori.
    if ($napakeZapored -eq 3) {
        Poslji 'Termini bot: napaka' "Bot 3x zapored ni mogel prebrati strani s termini.`n$($_.Exception.Message)`nPreveri stran rocno." 'high' 'warning'
    }
    Shrani-Stanje
    exit 0
}

if ($napakeZapored -ge 3) {
    Poslji 'Termini bot spet dela' 'Stran s termini je spet dosegljiva, spremljanje se nadaljuje.' 'default' 'white_check_mark'
}
$napakeZapored = 0

$dobri = @($termini | Where-Object { $_.Datum -le $Meja })
$novi  = @($dobri | Where-Object { $javljeni -notcontains $_.Kljuc })
Zapisi "Prostih terminov za voznjo: $($termini.Count), od tega dovolj zgodnjih: $($dobri.Count), novih: $($novi.Count)."

if ($novi.Count -gt 0) {
    $seznam = ($novi | ForEach-Object { Opis $_ }) -join "`n"
    Poslji 'PROST ZGODNEJSI TERMIN - voznja Kranj' "$seznam`nCim prej na upravno enoto Kranj. Tapni za stran s termini." 'urgent' 'rotating_light,car'
}
# Pozabi termine, ki jih ni vec; ce se spet sprostijo, jih javi znova.
$javljeni = @($dobri | ForEach-Object { $_.Kljuc })

$najzgodnejsi = if ($termini.Count) { Opis $termini[0] } else { 'ni prostih terminov' }

if ($Test) {
    Poslji 'Termini bot: test' "Bot dela.`nNajzgodnejsi prost termin: $najzgodnejsi`nDovolj zgodnjih (do $($Meja.ToString('d. M.'))): $($dobri.Count)" 'default' 'test_tube'
}

# Enkrat na dan (po 8. uri) sporoci, da bot se dela.
$danesNiz = $danes.ToString('yyyy-MM-dd')
if ($zdaj.Hour -ge 8 -and $zadnjiZivSem -ne $danesNiz) {
    Poslji 'Termini bot dela' "Najzgodnejsi prost termin: $najzgodnejsi`nIscem termine do $($Meja.ToString('d. M. yyyy'))." 'low' 'robot'
    $zadnjiZivSem = $danesNiz
}

Shrani-Stanje

# ArgenRadio - importar canciones desde una carpeta de origen
#
# Lee:   <Origen>\<Genero>\<Artista>\*.ogg
# Copia: 42\media\sound\argenradio\<genero>\<Artista>\<titulo-sanitizado>.ogg
# y escribe manifiestos para que el generador conserve los titulos visibles:
#   42\media\sound\argenradio\<genero>\artistas.txt       (carpeta=Nombre visible)
#   42\media\sound\argenradio\<genero>\<artista>\titulos.txt (archivo=Titulo visible)
#
# Los nombres de archivo quedan en ASCII sin espacios (los sound scripts de PZ
# no usan rutas con espacios ni caracteres no-ASCII). Los acentos se conservan
# solo en los manifiestos, o sea en lo que ve el jugador.
#
# Uso:
#   .\importar-canciones.ps1                      # usa C:\Users\franc\Desktop\musicapz
#   .\importar-canciones.ps1 -Origen "D:\musica"  # otra carpeta
#   .\importar-canciones.ps1 -SoloGenero cumbia   # solo un genero
#
# Despues de importar hay que ejecutar generar-biblioteca.cmd.

param(
    [string]$Origen = "C:\Users\franc\Desktop\musicapz",
    [string]$Destino,
    [string]$SoloGenero = ""
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$modRoot = Split-Path -Parent $scriptDir
if (-not $Destino) {
    $Destino = Join-Path $modRoot "42\media\sound\argenradio"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Nombres de genero conocidos: carpeta destino y nombre visible.
$genreMap = @{
    "rock-nacional" = @{ folder = "rocknacional"; nombre = "Rock Nacional" }
    "rocknacional"  = @{ folder = "rocknacional"; nombre = "Rock Nacional" }
    "cumbia"        = @{ folder = "cumbia";       nombre = "Cumbia" }
    "cuarteto"      = @{ folder = "cuarteto";     nombre = "Cuarteto" }
    "lentos"        = @{ folder = "lentos";       nombre = "Lentos" }
    "folklore"      = @{ folder = "folklore";     nombre = "Folklore" }
    "rkt"           = @{ folder = "rkt";          nombre = "RKT" }
}

# Carpetas de artista que necesitan acentos o alias en el nombre visible.
# Se arman con [char] para que el .ps1 quede en ASCII puro (PowerShell 5.1
# lee los .ps1 sin BOM como ANSI y rompe los acentos literales).
$eAcute = [string][char]0x00E9
$aAcute = [string][char]0x00E1
$iAcute = [string][char]0x00ED
$artistNames = @{
    "andres-calamaro" = "Andr$eAcute" + "s Calamaro"
    "babasonicos"     = "Bab$aAcute" + "sonicos"
    "charly-garcia"   = "Charly Garc$iAcute" + "a"
    "patricio-rey"    = "Patricio Rey"
    "los-piojos"      = "Los Piojos"
    "intoxicados"     = "Intoxicados"
    "virus"           = "Virus"
    "lechuga"         = "Lechuga"
}

# Alias que pueden aparecer como prefijo/sufijo "- Artista" en el nombre del archivo.
$artistAliases = @{
    "lechuga" = @("la banda de lechuga")
}

function Remove-Diacritics([string]$s) {
    if (-not $s) { return "" }
    $norm = $s.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $norm.ToCharArray()) {
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($cat -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
}

function ConvertTo-AsciiSlug([string]$s) {
    $t = Remove-Diacritics $s
    $t = $t.ToLowerInvariant()
    $t = [regex]::Replace($t, "[^a-z0-9]+", "-")
    $t = $t.Trim("-")
    if ($t.Length -gt 70) { $t = $t.Substring(0, 70).Trim("-") }
    if ($t -eq "") { $t = "tema" }
    return $t
}

function Get-FolderKey([string]$name) {
    $t = Remove-Diacritics $name
    $t = $t.ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    return $t.Trim("-")
}

# ---------------------------------------------------------------- manifiestos

function Read-Manifest([string]$path) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $map }
    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        $trim = $line.Trim()
        if ($trim -eq "" -or $trim.StartsWith("#")) { continue }
        $idx = $trim.IndexOf("=")
        if ($idx -lt 1) { continue }
        $key = $trim.Substring(0, $idx).Trim().ToLowerInvariant()
        $val = $trim.Substring($idx + 1).Trim()
        if ($key -ne "" -and $val -ne "") { $map[$key] = $val }
    }
    return $map
}

function Write-Manifest([string]$path, [hashtable]$map, [string[]]$order) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# ArgenRadio - manifiesto de la importacion. Editable a mano.")
    $lines.Add("# Formato: clave=valor")
    $lines.Add("")
    $seen = @{}
    foreach ($k in $order) {
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        if ($map.ContainsKey($k)) { $lines.Add("$k=" + $map[$k]) }
    }
    foreach ($k in ($map.Keys | Sort-Object)) {
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $lines.Add("$k=" + $map[$k])
    }
    [System.IO.File]::WriteAllLines($path, $lines, $utf8NoBom)
}

# ---------------------------------------------------------------- titulos

function Test-ArtistToken([string]$token, [string]$artistKey) {
    $tok = Get-FolderKey $token
    if ($tok -eq "") { return $false }
    $names = @($artistKey)
    if ($artistAliases.ContainsKey($artistKey)) {
        $names += $artistAliases[$artistKey]
    }
    foreach ($n in $names) {
        $nk = Get-FolderKey $n
        if ($tok -eq $nk) { return $true }
        if ($nk.Length -ge 4 -and $tok.EndsWith("-" + $nk)) { return $true }
    }
    return $false
}

function ConvertTo-SongTitle([string]$fileName, [string]$artistKey) {
    $t = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    # Signos de ancho completo que aparecen en algunos nombres.
    $t = $t.Replace([string][char]0xFF1F, "?").Replace([string][char]0xFF01, "!")
    # Ruido de YouTube: (Con letra), (video con Letra), (Canta ...), etc.
    $noise = "(?i)\s*\((?:con\s+letra|video\s+con\s+letra|letra|lyric\s+video|video\s*oficial|audio\s*oficial|canta\s+[^)]*|en\s+vivo)\)"
    $prev = $null
    while ($prev -ne $t) {
        $prev = $t
        $t = [regex]::Replace($t, $noise, "")
    }
    $t = $t.Trim()
    # Prefijo "Artista - Tema" o sufijo "Tema - Artista".
    if ($t -match "^(.+?)\s+-\s+(.+)$") {
        $pre = $Matches[1]
        $post = $Matches[2]
        if (Test-ArtistToken $pre $artistKey) {
            $t = $post
        } elseif (Test-ArtistToken $post $artistKey) {
            $t = $pre
        }
    }
    $t = $t -replace "[_]+", " "
    $t = $t -replace "\s+", " "
    $t = $t.Trim()
    if ($t -eq "") { $t = [System.IO.Path]::GetFileNameWithoutExtension($fileName) }
    return $t
}

function Get-TitleScore([string]$fileName) {
    $low = $fileName.ToLowerInvariant()
    if ($low -match "con letra|lyric|video") { return 0 }
    return 1
}

# ---------------------------------------------------------------- principal

if (-not (Test-Path -LiteralPath $Origen)) {
    throw "No existe la carpeta de origen: $Origen"
}

$report = New-Object System.Collections.Generic.List[object]
$copied = 0
$skipped = 0

foreach ($genreDirSrc in @(Get-ChildItem -LiteralPath $Origen -Directory | Sort-Object Name)) {
    $genreKey = Get-FolderKey $genreDirSrc.Name
    if ($SoloGenero -ne "" -and (Get-FolderKey $SoloGenero) -ne $genreKey) { continue }

    if ($genreMap.ContainsKey($genreKey)) {
        $genreFolder = $genreMap[$genreKey].folder
        $genreNombre = $genreMap[$genreKey].nombre
    } else {
        $genreFolder = $genreKey
        $genreNombre = $genreDirSrc.Name
    }

    $genreDst = Join-Path $Destino $genreFolder
    New-Item -ItemType Directory -Force -Path $genreDst | Out-Null

    $artistManifestPath = Join-Path $genreDst "artistas.txt"
    $artistManifest = Read-Manifest $artistManifestPath
    $artistOrder = @()
    $albumByArtist = @{}

    foreach ($artistDirSrc in @(Get-ChildItem -LiteralPath $genreDirSrc.FullName -Directory | Sort-Object Name)) {
        $artistKey = Get-FolderKey $artistDirSrc.Name
        $artistDisplay = $artistDirSrc.Name
        if ($artistNames.ContainsKey($artistKey)) { $artistDisplay = $artistNames[$artistKey] }
        if ($artistManifest.ContainsKey($artistKey)) { $artistDisplay = $artistManifest[$artistKey] }
        $artistManifest[$artistKey] = $artistDisplay
        $artistOrder += $artistKey

        $files = @(Get-ChildItem -LiteralPath $artistDirSrc.FullName -File -Filter "*.ogg" | Sort-Object Name)
        if ($files.Count -eq 0) { continue }

        # Limpiar titulos y descartar duplicados de la misma cancion.
        $entries = @()
        foreach ($f in $files) {
            $entries += [PSCustomObject]@{
                File  = $f
                Title = ConvertTo-SongTitle $f.Name $artistKey
                Score = Get-TitleScore $f.Name
                Size  = $f.Length
            }
        }
        $groups = $entries | Group-Object { ConvertTo-AsciiSlug $_.Title }
        $chosen = @()
        foreach ($g in $groups) {
            $best = $g.Group | Sort-Object Score, Size -Descending | Select-Object -First 1
            $chosen += $best
            if ($g.Count -gt 1) {
                $dropped = ($g.Group | Where-Object { $_.File.FullName -ne $best.File.FullName } | ForEach-Object { $_.File.Name }) -join ", "
                $report.Add([PSCustomObject]@{ Genero = $genreNombre; Artista = $artistDisplay; Archivo = $best.File.Name; Titulo = $best.Title; Estado = "duplicado descartado: $dropped" })
                $script:skipped++
            }
        }

        $artistDst = Join-Path $genreDst $artistKey
        New-Item -ItemType Directory -Force -Path $artistDst | Out-Null
        $titlePath = Join-Path $artistDst "titulos.txt"
        $titleManifest = Read-Manifest $titlePath
        $titleOrder = @()
        $used = @{}

        foreach ($e in ($chosen | Sort-Object { $_.File.Name })) {
            $slug = ConvertTo-AsciiSlug $e.Title
            $fileName = "$slug.ogg"
            $n = 2
            while ($used.ContainsKey($fileName)) {
                $fileName = "$slug-$n.ogg"
                $n++
            }
            $used[$fileName] = $true
            $titleOrder += $fileName.ToLowerInvariant()

            $target = Join-Path $artistDst $fileName
            Copy-Item -LiteralPath $e.File.FullName -Destination $target -Force
            $script:copied++

            $key = $fileName.ToLowerInvariant()
            if ($titleManifest.ContainsKey($key)) {
                $finalTitle = $titleManifest[$key]
            } else {
                $finalTitle = $e.Title
                $titleManifest[$key] = $finalTitle
            }

            $report.Add([PSCustomObject]@{ Genero = $genreNombre; Artista = $artistDisplay; Archivo = $fileName; Titulo = $finalTitle; Estado = "ok" })
        }

        Write-Manifest $titlePath $titleManifest $titleOrder
    }

    Write-Manifest $artistManifestPath $artistManifest $artistOrder
}

Write-Host ""
Write-Host ("Importadas: " + $copied + " | Duplicadas descartadas: " + $skipped)
Write-Host ("Destino: " + $Destino)
Write-Host ""
$report | Format-Table -AutoSize -Wrap

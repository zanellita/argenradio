# ArgenRadio - generador de biblioteca y sound scripts
# Lee las carpetas:
#   42\media\sound\argenradio\<genero>\<artista>\*.ogg
# y escribe:
#   42\media\lua\shared\ArgenRadio\ArgenRadio_Library.lua
#   42\media\scripts\argenradio_sounds.txt
#
# Uso: doble clic en generar-biblioteca.cmd (o ejecutar este .ps1).

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$modRoot = Split-Path -Parent $scriptDir
$mediaDir = Join-Path $modRoot "42\media"
$soundRoot = Join-Path $mediaDir "sound\argenradio"
$libraryPath = Join-Path $mediaDir "lua\shared\ArgenRadio\ArgenRadio_Library.lua"
$scriptsPath = Join-Path $mediaDir "scripts\argenradio_sounds.txt"

# El orden de esta lista es el orden del dial y de la sincronizacion.
# No cambiar el orden sin regenerar en todas las maquinas.
$genres = @(
    @{ folder = "rocknacional"; nombre = "Rock Nacional"; freq = "101.5"; key = "RockNacional" },
    @{ folder = "cumbia";       nombre = "Cumbia";        freq = "92.7";  key = "Cumbia" },
    @{ folder = "cuarteto";     nombre = "Cuarteto";      freq = "88.9";  key = "Cuarteto" },
    @{ folder = "lentos";       nombre = "Lentos";        freq = "95.3";  key = "Lentos" },
    @{ folder = "folklore";     nombre = "Folklore";      freq = "104.1"; key = "Folklore" },
    @{ folder = "rkt";          nombre = "RKT";           freq = "107.9"; key = "RKT" }
)

function ConvertTo-DisplayName([string]$raw) {
    if (-not $raw) { return "" }
    $name = $raw -replace "[_\-]+", " "
    $name = $name -replace "\s+", " "
    $name = $name.Trim()
    if ($name -eq "") { return $raw }
    # Si la carpeta ya viene con mayusculas, respetarlas (RKT, AC/DC, etc.).
    if ($name -cmatch "[A-Z]") { return $name }
    return (Get-Culture).TextInfo.ToTitleCase($name.ToLower())
}

function ConvertTo-Slug([string]$raw) {
    if (-not $raw) { return "" }
    $slug = $raw.ToLower() -replace "[^a-z0-9]+", "-"
    $slug = $slug.Trim("-")
    if ($slug -eq "") { return "artista" }
    return $slug
}

function ConvertTo-SongTitle([string]$fileName) {
    $title = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $title = $title -replace "_", " "
    $title = $title -replace "\s+", " "
    $title = $title.Trim()
    # Sacar prefijos de pista tipo "01 - ", "02. ", "03) ".
    $title = $title -replace "^\d{1,3}\s*[\-\.\)]\s*", ""
    $title = $title.Trim()
    if ($title -eq "") {
        $title = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    }
    if ($title -cnotmatch "[A-Z]") {
        $title = (Get-Culture).TextInfo.ToTitleCase($title.ToLower())
    }
    return $title
}

function ConvertTo-LuaString([string]$value) {
    if ($null -eq $value) { return "" }
    return $value.Replace("\", "\\").Replace('"', '\"').Replace("`r", "\r").Replace("`n", "\n")
}

function Get-OggFiles([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-ChildItem -LiteralPath $path -File -Filter "*.ogg" | Sort-Object Name)
}

if (-not (Test-Path -LiteralPath $soundRoot)) {
    throw "No existe la carpeta de musica: $soundRoot"
}

$libraryLines = New-Object System.Collections.Generic.List[string]
$scriptLines = New-Object System.Collections.Generic.List[string]
$totalSongs = 0
$totalArtists = 0

$libraryLines.Add("-- ArgenRadio - biblioteca generada automaticamente.")
$libraryLines.Add("-- No editar a mano: ejecutar Herramientas\generar-biblioteca.cmd")
$libraryLines.Add("-- Generado: " + (Get-Date -Format "yyyy-MM-dd HH:mm"))
$libraryLines.Add("")
$libraryLines.Add("ArgenRadio = ArgenRadio or {}")
$libraryLines.Add("")
$libraryLines.Add("ArgenRadio.Library = {")
$libraryLines.Add("    stations = {")

$scriptLines.Add("module Base")
$scriptLines.Add("{")

foreach ($genre in $genres) {
    $genreDir = Join-Path $soundRoot $genre.folder
    $artistEntries = @()

    if (Test-Path -LiteralPath $genreDir) {
        $usedIds = @{}
        $artistDirs = @(Get-ChildItem -LiteralPath $genreDir -Directory | Sort-Object Name)
        foreach ($dir in $artistDirs) {
            $files = Get-OggFiles $dir.FullName
            if ($files.Count -eq 0) { continue }

            $display = ConvertTo-DisplayName $dir.Name
            $id = ConvertTo-Slug $dir.Name
            if ($usedIds.ContainsKey($id)) {
                $n = 2
                while ($usedIds.ContainsKey("$id-$n")) { $n++ }
                $id = "$id-$n"
            }
            $usedIds[$id] = $true

            $artistEntries += @{
                folder = $dir.Name
                id = $id
                nombre = $display
                files = $files
            }
        }

        # .ogg sueltos en la raiz del genero -> artista "Sueltos".
        $rootFiles = Get-OggFiles $genreDir
        if ($rootFiles.Count -gt 0) {
            $artistEntries += @{
                folder = ""
                id = "sueltos"
                nombre = "Sueltos"
                files = $rootFiles
            }
        }
    }

    if ($artistEntries.Count -eq 0) {
        Write-Warning ("Sin canciones en el genero " + $genre.folder + " (" + $genreDir + ")")
    }

    $libraryLines.Add("        {")
    $libraryLines.Add("            id = `"$($genre.folder)`", nombre = `"$(ConvertTo-LuaString $genre.nombre)`", freq = `"$($genre.freq)`",")
    $libraryLines.Add("            artists = {")

    $songNumber = 0
    foreach ($artist in $artistEntries) {
        $totalArtists++
        $libraryLines.Add("                {")
        $libraryLines.Add("                    id = `"$(ConvertTo-LuaString $artist.id)`", nombre = `"$(ConvertTo-LuaString $artist.nombre)`",")
        $libraryLines.Add("                    tracks = {")

        foreach ($file in $artist.files) {
            $songNumber++
            $totalSongs++
            $soundName = "ArgenRadio_$($genre.key)_" + $songNumber.ToString("000")
            $title = ConvertTo-SongTitle $file.Name

            $libraryLines.Add("                        { sound = `"$soundName`", titulo = `"$(ConvertTo-LuaString $title)`", artista = `"$(ConvertTo-LuaString $artist.nombre)`" },")

            if ($artist.folder -eq "") {
                $relative = "media/sound/argenradio/$($genre.folder)/$($file.Name)"
            } else {
                $relative = "media/sound/argenradio/$($genre.folder)/$($artist.folder)/$($file.Name)"
            }

            $scriptLines.Add("    sound $soundName")
            $scriptLines.Add("    {")
            $scriptLines.Add("        category = Vehicle,")
            $scriptLines.Add("        clip")
            $scriptLines.Add("        {")
            $scriptLines.Add("            file = $relative,")
            $scriptLines.Add("            distanceMax = 60,")
            $scriptLines.Add("        }")
            $scriptLines.Add("    }")
        }

        $libraryLines.Add("                    },")
        $libraryLines.Add("                },")
    }

    $libraryLines.Add("            },")
    $libraryLines.Add("        },")
}

$libraryLines.Add("    },")
$libraryLines.Add("}")
$libraryLines.Add("")
$scriptLines.Add("}")

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($libraryPath, ($libraryLines -join "`n") + "`n", $utf8NoBom)
[System.IO.File]::WriteAllText($scriptsPath, ($scriptLines -join "`n") + "`n", $utf8NoBom)

Write-Host ""
Write-Host ("Listo: " + $totalSongs + " canciones, " + $totalArtists + " artistas, " + $genres.Count + " generos.")
Write-Host ("Biblioteca: " + $libraryPath)
Write-Host ("Sound scripts: " + $scriptsPath)

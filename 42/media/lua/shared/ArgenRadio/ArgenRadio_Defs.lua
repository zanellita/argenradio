-- ArgenRadio - definiciones compartidas (cliente y servidor)
-- Biblioteca genero -> artista -> canciones. El archivo de datos lo genera
-- Herramientas/generar-biblioteca.ps1 (ArgenRadio_Library.lua).

ArgenRadio = ArgenRadio or {}

ArgenRadio.VERSION = "0.6.0"

-- Modos de reproduccion por ambito. "random" elige al azar (tema inicial,
-- siguiente y anterior); "list" recorre la lista en orden con vuelta.
ArgenRadio.MODE_RANDOM = "random"
ArgenRadio.MODE_LIST = "list"
-- Historial del ambito actual: se descarta al cambiar de emisora, artista
-- o modo, para no guardar el recorrido de todo lo escuchado.
ArgenRadio.HISTORY_MAX = 20

-- Si falta el archivo generado, dejamos las emisoras sin artistas para que
-- la ventana no se rompa; el generador crea ArgenRadio_Library.lua.
if not ArgenRadio.Library then
    ArgenRadio.Library = {
        stations = {
            { id = "rocknacional", nombre = "Rock Nacional", freq = "101.5", artists = {} },
            { id = "cumbia", nombre = "Cumbia", freq = "92.7", artists = {} },
            { id = "cuarteto", nombre = "Cuarteto", freq = "88.9", artists = {} },
            { id = "lentos", nombre = "Lentos", freq = "95.3", artists = {} },
            { id = "folklore", nombre = "Folklore", freq = "104.1", artists = {} },
            { id = "rkt", nombre = "RKT", freq = "107.9", artists = {} },
        },
    }
end

function ArgenRadio.getStations()
    return ArgenRadio.Library and ArgenRadio.Library.stations or {}
end

-- Devuelve la emisora y el indice normalizado (1..N).
function ArgenRadio.getStation(index)
    local stations = ArgenRadio.getStations()
    local n = #stations
    if n == 0 then return nil, 1 end
    index = tonumber(index) or 1
    index = math.floor(index)
    if index < 1 then index = 1 end
    if index > n then index = ((index - 1) % n) + 1 end
    return stations[index], index
end

function ArgenRadio.getStationName(index)
    local station = ArgenRadio.getStation(index)
    return station and station.nombre or "ArgenRadio"
end

function ArgenRadio.getStationArtists(index)
    local station = ArgenRadio.getStation(index)
    return station and station.artists or {}
end

-- Devuelve el artista por id, o nil si no existe en la emisora.
function ArgenRadio.getArtist(stationIndex, artistId)
    if not artistId or artistId == "" then return nil end
    local artists = ArgenRadio.getStationArtists(stationIndex)
    for i = 1, #artists do
        if artists[i].id == artistId then return artists[i], i end
    end
    return nil
end

function ArgenRadio.isValidArtist(stationIndex, artistId)
    if not artistId or artistId == "" then return true end
    return ArgenRadio.getArtist(stationIndex, artistId) ~= nil
end

-- Nombre visible del ambito actual: el artista o "Todo el genero".
function ArgenRadio.getScopeName(stationIndex, artistId)
    local artist = ArgenRadio.getArtist(stationIndex, artistId)
    return artist and artist.nombre or "Todo el genero"
end

-- Lista plana de temas de una emisora (todos los artistas, en orden).
-- El indice plano es el que viaja por la red y el que usa el dial.
function ArgenRadio.getStationTracks(stationIndex)
    local station = ArgenRadio.getStation(stationIndex)
    if not station then return {} end
    if station._tracks then return station._tracks end

    local tracks = {}
    local artists = station.artists or {}
    for i = 1, #artists do
        local artist = artists[i]
        local list = artist.tracks or {}
        for j = 1, #list do
            local track = list[j]
            track.artistId = artist.id
            if not track.artista then track.artista = artist.nombre end
            track.index = #tracks + 1
            tracks[#tracks + 1] = track
        end
    end
    station._tracks = tracks
    return tracks
end

-- Temas del ambito actual: todo el genero o un artista puntual.
function ArgenRadio.getScopeTracks(stationIndex, artistId)
    local all = ArgenRadio.getStationTracks(stationIndex)
    if not artistId or artistId == "" then return all end

    local scope = {}
    for i = 1, #all do
        if all[i].artistId == artistId then
            scope[#scope + 1] = all[i]
        end
    end
    return scope
end

-- Devuelve el tema y el indice normalizado (1..N).
function ArgenRadio.getTrack(stationIndex, trackIndex)
    local tracks = ArgenRadio.getStationTracks(stationIndex)
    local n = #tracks
    if n == 0 then return nil, 1 end
    trackIndex = tonumber(trackIndex) or 1
    trackIndex = math.floor(trackIndex)
    if trackIndex < 1 then trackIndex = 1 end
    if trackIndex > n then trackIndex = ((trackIndex - 1) % n) + 1 end
    return tracks[trackIndex], trackIndex
end

function ArgenRadio.getTrackSound(stationIndex, trackIndex)
    local track = ArgenRadio.getTrack(stationIndex, trackIndex)
    return track and track.sound or nil
end

function ArgenRadio.getTrackTitle(stationIndex, trackIndex)
    local track = ArgenRadio.getTrack(stationIndex, trackIndex)
    if not track then return "--" end
    if track.artista and track.artista ~= "" then
        return track.artista .. " - " .. (track.titulo or "--")
    end
    return track.titulo or "--"
end

-- Modo del ambito activo (artista si hay uno elegido; si no, genero).
function ArgenRadio.getActiveMode(state)
    if not state then return ArgenRadio.MODE_RANDOM end
    if state.artist and state.artist ~= "" then
        return state.artistMode or ArgenRadio.MODE_RANDOM
    end
    return state.genreMode or ArgenRadio.MODE_RANDOM
end

function ArgenRadio.normalizeMode(mode, fallback)
    if mode == ArgenRadio.MODE_LIST then return ArgenRadio.MODE_LIST end
    if mode == ArgenRadio.MODE_RANDOM then return ArgenRadio.MODE_RANDOM end
    return fallback or ArgenRadio.MODE_RANDOM
end

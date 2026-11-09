-- ArgenRadio - definiciones compartidas (cliente y servidor)
-- Etapa 4: playlist por emisora, con pistas de prueba por genero.

ArgenRadio = ArgenRadio or {}

ArgenRadio.VERSION = "0.4.3"

-- Cada emisora tiene una carpeta propia dentro de media/sound/argenradio/
-- y una lista de temas. El campo sound coincide con el sound script de
-- media/scripts/argenradio_sounds.txt.
-- freq es estetico; la marca del dial se ubica segun la frecuencia.
ArgenRadio.STATIONS = {
    {
        id = "rocknacional", nombre = "Rock Nacional", freq = "101.5",
        tracks = {
            { sound = "ArgenRadio_RockNacional_1", titulo = "Prueba 1" },
            { sound = "ArgenRadio_RockNacional_2", titulo = "Prueba 2" },
            { sound = "ArgenRadio_RockNacional_3", titulo = "Prueba 3" },
        },
    },
    {
        id = "cumbia", nombre = "Cumbia", freq = "92.7",
        tracks = {
            { sound = "ArgenRadio_Cumbia_1", titulo = "Prueba 1" },
            { sound = "ArgenRadio_Cumbia_2", titulo = "Prueba 2" },
            { sound = "ArgenRadio_Cumbia_3", titulo = "Prueba 3" },
        },
    },
    {
        id = "cuarteto", nombre = "Cuarteto", freq = "88.9",
        tracks = {
            { sound = "ArgenRadio_Cuarteto_1", titulo = "Prueba 1" },
            { sound = "ArgenRadio_Cuarteto_2", titulo = "Prueba 2" },
            { sound = "ArgenRadio_Cuarteto_3", titulo = "Prueba 3" },
        },
    },
    {
        id = "lentos", nombre = "Lentos", freq = "95.3",
        tracks = {
            { sound = "ArgenRadio_Lentos_1", titulo = "Prueba 1" },
            { sound = "ArgenRadio_Lentos_2", titulo = "Prueba 2" },
            { sound = "ArgenRadio_Lentos_3", titulo = "Prueba 3" },
        },
    },
    {
        id = "folklore", nombre = "Folklore", freq = "104.1",
        tracks = {
            { sound = "ArgenRadio_Folklore_1", titulo = "Prueba 1" },
            { sound = "ArgenRadio_Folklore_2", titulo = "Prueba 2" },
            { sound = "ArgenRadio_Folklore_3", titulo = "Prueba 3" },
        },
    },
    {
        id = "rkt", nombre = "RKT", freq = "107.9",
        tracks = {
            { sound = "ArgenRadio_RKT_1", titulo = "Prueba 1" },
            { sound = "ArgenRadio_RKT_2", titulo = "Prueba 2" },
            { sound = "ArgenRadio_RKT_3", titulo = "Prueba 3" },
        },
    },
}

-- Devuelve la emisora y el indice normalizado (1..N).
function ArgenRadio.getStation(index)
    local n = #ArgenRadio.STATIONS
    if n == 0 then return nil, 1 end
    index = tonumber(index) or 1
    index = math.floor(index)
    if index < 1 then index = 1 end
    if index > n then index = ((index - 1) % n) + 1 end
    return ArgenRadio.STATIONS[index], index
end

function ArgenRadio.getStationName(index)
    local station = ArgenRadio.getStation(index)
    return station and station.nombre or "ArgenRadio"
end

-- Lista de temas de una emisora (puede estar vacia).
function ArgenRadio.getStationTracks(index)
    local station = ArgenRadio.getStation(index)
    if not station or not station.tracks then return {} end
    return station.tracks
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
    return track and track.titulo or "--"
end

-- Compatibilidad con la etapa 3: primer tema de la emisora.
function ArgenRadio.getStationSound(index)
    return ArgenRadio.getTrackSound(index, 1)
end

local totalTracks = 0
for i = 1, #ArgenRadio.STATIONS do
    totalTracks = totalTracks + #ArgenRadio.STATIONS[i].tracks
end

print("[ArgenRadio] v" .. ArgenRadio.VERSION .. " cargado ("
    .. #ArgenRadio.STATIONS .. " emisoras, " .. totalTracks .. " temas)")

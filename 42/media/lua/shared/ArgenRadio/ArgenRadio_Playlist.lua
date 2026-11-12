-- ArgenRadio - seleccion de temas compartida (cliente y servidor)
-- Implementa los modos aleatorio / en fila y el historial del ambito actual.
-- El generador aleatorio se recibe por parametro: el cliente usa su Lehmer
-- (Kahlua no garantiza math.random) y el servidor usa ZombRand.

ArgenRadio = ArgenRadio or {}
ArgenRadio.Playlist = ArgenRadio.Playlist or {}

local P = ArgenRadio.Playlist

local function clampPick(value, count)
    value = tonumber(value) or 1
    value = math.floor(value)
    if value < 1 then value = 1 end
    if value > count then value = ((value - 1) % count) + 1 end
    return value
end

local function scopeOf(state)
    return ArgenRadio.getScopeTracks(state.station, state.artist)
end

function P.getMode(state)
    return ArgenRadio.getActiveMode(state)
end

function P.clearHistory(state)
    state.history = {}
end

-- Guarda el tema actual antes de saltar al azar. Solo se conserva el
-- recorrido del ambito vigente y con un tope chico de memoria.
function P.historyPush(state, trackIndex)
    if not trackIndex then return end
    local history = state.history
    if type(history) ~= "table" then
        history = {}
        state.history = history
    end
    if history[#history] == trackIndex then return end

    history[#history + 1] = trackIndex
    while #history > ArgenRadio.HISTORY_MAX do
        for i = 2, #history do
            history[i - 1] = history[i]
        end
        history[#history] = nil
    end
end

-- Devuelve el tema anterior real dentro del ambito, o nil si no hay.
function P.historyPop(state, tracks)
    local history = state.history
    if type(history) ~= "table" then return nil end

    while #history > 0 do
        local candidate = history[#history]
        history[#history] = nil
        for i = 1, #tracks do
            if tracks[i].index == candidate then
                return candidate
            end
        end
    end
    return nil
end

local function pickRandom(tracks, currentIndex, rng)
    local count = #tracks
    if count == 0 then return nil end
    if count == 1 then return tracks[1].index end

    local pick = tracks[clampPick(rng and rng(count) or 1, count)].index
    if pick ~= currentIndex then return pick end

    -- Si el azar repitio el actual, avanzamos uno en la lista del ambito.
    for i = 1, count do
        if tracks[i].index == currentIndex then
            return tracks[(i % count) + 1].index
        end
    end
    return tracks[1].index
end

-- Tema con el que arranca una emisora o un artista. En modo fila empieza
-- por el primero; en aleatorio, por cualquiera del ambito.
function P.pickStart(state, rng)
    local tracks = scopeOf(state)
    if #tracks == 0 then return nil end

    state.history = {}
    if ArgenRadio.getActiveMode(state) == ArgenRadio.MODE_LIST then
        return tracks[1].index
    end
    return tracks[clampPick(rng and rng(#tracks) or 1, #tracks)].index
end

-- Avanza (delta = 1) o retrocede (delta = -1) dentro del ambito.
-- En modo fila recorre la lista con vuelta. En aleatorio, "siguiente"
-- sortea y "anterior" vuelve por el historial del ambito actual.
function P.step(state, delta, rng)
    local tracks = scopeOf(state)
    if #tracks == 0 then return nil end

    delta = tonumber(delta) or 1
    if delta < 0 then delta = -1 else delta = 1 end

    if ArgenRadio.getActiveMode(state) == ArgenRadio.MODE_LIST then
        state.history = {}
        local current = 1
        for i = 1, #tracks do
            if tracks[i].index == state.track then
                current = i
                break
            end
        end
        local nextPos = ((current - 1 + delta) % #tracks) + 1
        return tracks[nextPos].index
    end

    if delta > 0 then
        P.historyPush(state, state.track)
        return pickRandom(tracks, state.track, rng)
    end

    local previous = P.historyPop(state, tracks)
    if previous then return previous end
    return pickRandom(tracks, state.track, rng)
end

if ArgenRadio.getStations then
    local stations = ArgenRadio.getStations()
    local totalArtists = 0
    local totalTracks = 0
    for i = 1, #stations do
        totalArtists = totalArtists + #(stations[i].artists or {})
        totalTracks = totalTracks + #ArgenRadio.getStationTracks(i)
    end

    print("[ArgenRadio] v" .. tostring(ArgenRadio.VERSION) .. " cargado ("
        .. #stations .. " emisoras, " .. totalArtists .. " artistas, "
        .. totalTracks .. " temas)")
end

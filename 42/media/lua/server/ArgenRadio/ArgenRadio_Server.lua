-- ArgenRadio - sincronizacion multijugador (etapa 5)
-- El servidor es la autoridad de la radio del auto. Guarda el estado en
-- vehicle:getModData().argenRadio y lo retransmite por comandos propios.
-- Cada cliente recrea su sesion local a partir de ese estado.
--
-- La biblioteca es genero -> artista -> canciones. El servidor decide el
-- tema segun el ambito (todo el genero o un artista), el modo aleatorio/fila
-- y el historial del ambito actual.
--
-- Alcance: solo radio de vehiculo. Las radios de casa y las portatiles
-- siguen con el comportamiento local.

if not isServer() then return end

ArgenRadio = ArgenRadio or {}

local MODULE = "ArgenRadio"
local DEFAULT_VOLUME = 0.7
-- Un poco mas holgada que los 10 tiles a los que se cierra la ventana
-- vanilla, para tolerar el movimiento del jugador.
local MAX_INTERACT_DISTANCE = 15
-- Reenvio periodico: late joiners y vehiculos que se recargan vuelven a
-- sincronizarse aunque hayan perdido el ultimo cambio.
local SYNC_INTERVAL_MS = 5000

local lastSyncMs = 0

-- ZombRand(n) devuelve 0..n-1. El Playlist espera un rng que devuelva 1..n.
local function randTrack(max)
    local value = math.floor(ZombRand(max) or 0) + 1
    if value < 1 then value = 1 end
    if value > max then value = max end
    return value
end

local function clampVolume(value)
    value = tonumber(value) or DEFAULT_VOLUME
    if value < 0 then value = 0 end
    if value > 1 then value = 1 end
    return value
end

local function newState()
    return {
        on = false,
        station = 1,
        track = 1,
        artist = "",
        genreMode = ArgenRadio.MODE_RANDOM,
        artistMode = ArgenRadio.MODE_RANDOM,
        history = {},
        volume = DEFAULT_VOLUME,
        muted = false,
        revision = 0,
    }
end

local function trackInScope(stationIndex, artist, trackIndex)
    local scope = ArgenRadio.getScopeTracks(stationIndex, artist)
    for i = 1, #scope do
        if scope[i].index == trackIndex then return true end
    end
    return false
end

local function getState(vehicle)
    local modData = vehicle:getModData()
    local state = modData.argenRadio
    if type(state) ~= "table" then
        state = newState()
        modData.argenRadio = state
    end

    local _, stationIndex = ArgenRadio.getStation(state.station)
    state.station = stationIndex
    state.artist = tostring(state.artist or "")
    if not ArgenRadio.isValidArtist(stationIndex, state.artist) then
        state.artist = ""
    end
    state.genreMode = ArgenRadio.normalizeMode(state.genreMode, ArgenRadio.MODE_RANDOM)
    state.artistMode = ArgenRadio.normalizeMode(state.artistMode, ArgenRadio.MODE_RANDOM)
    if type(state.history) ~= "table" then state.history = {} end

    local _, trackIndex = ArgenRadio.getTrack(stationIndex, state.track)
    -- Si la biblioteca cambio y el tema quedo fuera del artista elegido,
    -- arrancamos desde el primer tema valido del ambito.
    local scope = ArgenRadio.getScopeTracks(stationIndex, state.artist)
    if #scope > 0 and not trackInScope(stationIndex, state.artist, trackIndex) then
        trackIndex = scope[1].index
    end
    state.track = trackIndex

    state.on = state.on == true
    state.volume = clampVolume(state.volume)
    state.muted = state.muted == true
    state.revision = tonumber(state.revision) or 0
    return state
end

local function makePayload(vehicle, state)
    return {
        vehicle = vehicle:getId(),
        on = state.on,
        station = state.station,
        track = state.track,
        artist = state.artist,
        genreMode = state.genreMode,
        artistMode = state.artistMode,
        volume = state.volume,
        muted = state.muted,
        revision = state.revision,
    }
end

-- En un servidor hosteado el cliente local comparte el estado Lua, asi que
-- aplicamos el cambio en el momento sin esperar el viaje de red.
local function applyLocalHost(player, vehicle, state)
    if not isMultiplayer() then return end
    local localPlayer = getPlayer and getPlayer() or nil
    if not localPlayer then return end
    if player and player ~= localPlayer then return end
    if not (ArgenRadio.Audio and ArgenRadio.Audio.applyRemoteState) then return end
    ArgenRadio.Audio.applyRemoteState(vehicle:getId(), makePayload(vehicle, state))
end

local function broadcast(vehicle, state)
    sendServerCommand(MODULE, "state", makePayload(vehicle, state))
    applyLocalHost(nil, vehicle, state)
end

local function reply(player, vehicle, state)
    sendServerCommand(player, MODULE, "state", makePayload(vehicle, state))
    applyLocalHost(player, vehicle, state)
end

local function canInteract(player, vehicle)
    if not player or not vehicle then return false end
    local square = vehicle:getSquare()
    if not square then return false end
    if not player.DistTo then return false end
    return player:DistTo(square:getX(), square:getY()) <= MAX_INTERACT_DISTANCE
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then return end
    if not player then return end

    args = args or {}
    local vehicleId = tonumber(args.vehicle)
    if not vehicleId then return end

    local vehicle = getVehicleById(vehicleId)
    if not vehicle then return end
    if not vehicle:getPartById("Radio") then return end

    local state = getState(vehicle)

    -- Consultar no requiere cercania: cualquier cliente puede pedir el
    -- estado actual al abrir la ventana o al entrar en la zona.
    if command == "request" then
        reply(player, vehicle, state)
        return
    end

    -- El avance automatico lo gana un solo cliente: el que trae la
    -- revision vigente. El resto de los clientes recibe el estado nuevo.
    if command == "advance" then
        local revision = tonumber(args.revision)
        if not state.on or not revision or revision ~= state.revision then
            return
        end
        local track = ArgenRadio.Playlist.step(state, 1, randTrack)
        if not track then return end
        state.track = track
        state.revision = state.revision + 1
        broadcast(vehicle, state)
        return
    end

    -- El resto de las acciones exige estar cerca del vehiculo.
    if not canInteract(player, vehicle) then return end

    local changed = false

    if command == "play" then
        local _, stationIndex = ArgenRadio.getStation(args.station or state.station)
        if stationIndex ~= state.station then
            state.station = stationIndex
            state.artist = ""
            state.history = {}
        end

        if args.artist ~= nil then
            local artist = tostring(args.artist)
            if ArgenRadio.isValidArtist(state.station, artist) then
                if artist ~= state.artist then state.history = {} end
                state.artist = artist
            end
        end

        local requested = tonumber(args.track)
        if args.start == true then
            -- "Reproducir" sin tema puntual: arranca el ambito segun el modo.
            state.track = ArgenRadio.Playlist.pickStart(state, randTrack) or state.track
        elseif requested then
            local _, trackIndex = ArgenRadio.getTrack(state.station, requested)
            if trackInScope(state.station, state.artist, trackIndex) then
                state.track = trackIndex
            else
                state.track = ArgenRadio.Playlist.pickStart(state, randTrack) or state.track
            end
        elseif not trackInScope(state.station, state.artist, state.track) then
            state.track = ArgenRadio.Playlist.pickStart(state, randTrack) or state.track
        end

        state.volume = clampVolume(args.volume or state.volume)
        state.on = true
        state.revision = state.revision + 1
        changed = true

    elseif command == "stop" then
        if state.on then
            state.on = false
            state.revision = state.revision + 1
            changed = true
        end

    elseif command == "station" then
        local _, stationIndex = ArgenRadio.getStation(args.station or state.station)
        if stationIndex ~= state.station then
            state.station = stationIndex
            state.artist = ""
            state.track = ArgenRadio.Playlist.pickStart(state, randTrack) or state.track
            state.revision = state.revision + 1
            changed = true
        end

    elseif command == "scope" then
        local artist = tostring(args.artist or "")
        if not ArgenRadio.isValidArtist(state.station, artist) then artist = "" end
        if artist ~= state.artist then
            state.artist = artist
            state.track = ArgenRadio.Playlist.pickStart(state, randTrack) or state.track
            state.revision = state.revision + 1
            changed = true
        end

    elseif command == "mode" then
        local mode = ArgenRadio.normalizeMode(args.mode, ArgenRadio.MODE_RANDOM)
        local isArtist = (args.scope == "artist")
        local current = isArtist and state.artistMode or state.genreMode
        if current ~= mode then
            if isArtist then
                state.artistMode = mode
            else
                state.genreMode = mode
            end
            state.history = {}
            state.revision = state.revision + 1
            changed = true
        end

    elseif command == "select" then
        local requested = tonumber(args.track)
        if requested then
            local _, trackIndex = ArgenRadio.getTrack(state.station, requested)
            state.track = trackIndex
            state.history = {}
            state.revision = state.revision + 1
            changed = true
        end

    elseif command == "track" then
        local delta = tonumber(args.delta) or 1
        if delta < 0 then delta = -1 else delta = 1 end
        local track = ArgenRadio.Playlist.step(state, delta, randTrack)
        if track then
            state.track = track
            state.revision = state.revision + 1
            changed = true
        end

    elseif command == "volume" then
        local volume = clampVolume(args.volume)
        if volume ~= state.volume then
            state.volume = volume
            changed = true
        end

    elseif command == "mute" then
        local muted = args.muted == true
        if muted ~= state.muted then
            state.muted = muted
            changed = true
        end
    end

    if changed then
        broadcast(vehicle, state)
    end
end

-- Reenvio periodico de las radios encendidas. Es barato (solo vehiculos
-- cargados) y evita que un cliente quede desincronizado tras una recarga.
local function syncOnRadios()
    local now = getTimestampMs and getTimestampMs() or 0
    if now - lastSyncMs < SYNC_INTERVAL_MS then return end
    lastSyncMs = now

    local cell = getCell and getCell() or nil
    local vehicles = cell and cell:getVehicles() or nil
    if not vehicles then return end

    for i = 1, vehicles:size() do
        local vehicle = vehicles:get(i - 1)
        local modData = vehicle and vehicle:getModData() or nil
        local state = modData and modData.argenRadio or nil
        if type(state) == "table" and state.on == true then
            broadcast(vehicle, getState(vehicle))
        end
    end
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnTick.Add(syncOnRadios)

print("[ArgenRadio] Servidor MP listo (etapa 5)")

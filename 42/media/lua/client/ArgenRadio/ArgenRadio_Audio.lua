-- ArgenRadio - motor de audio del cliente
-- Reproduce la emisora elegida en el emitter del dispositivo:
--   * vehiculo  -> emitter propio del vehiculo (sigue sonando al bajarse)
--   * casa      -> emitter libre posicionado en el objeto
--   * portatil  -> emitter libre que sigue al jugador que la lleva
--
-- Etapa 5: la radio del vehiculo pasa por el servidor (ver ArgenRadio_Net.lua
-- y ArgenRadio_Server.lua). Las funciones *Local son el motor de siempre;
-- la API publica decide entre local y multijugador.
--
-- Biblioteca (v0.6): genero -> artista -> canciones. El ambito puede ser
-- todo el genero o un artista, y cada ambito tiene su modo aleatorio/fila.
-- El historial de "Tema anterior" solo vive mientras dura el ambito actual.

ArgenRadio = ArgenRadio or {}
ArgenRadio.Audio = ArgenRadio.Audio or {}

local Audio = ArgenRadio.Audio

local DEFAULT_VOLUME = 0.7
-- Margen para no confundir "todavia no arranco" con "ya termino".
local ADVANCE_GRACE_MS = 1500

-- Estado por dispositivo (emisora, artista, modo, tema, encendido, volumen).
local states = {}
-- Sesiones de audio activas por dispositivo.
local sessions = {}

-- Generador pseudoaleatorio propio: el Lua de Project Zomboid (Kahlua)
-- no garantiza math.random ni math.randomseed.
local rngState = math.floor((getTimestampMs and getTimestampMs() or os.time()) % 2147483646) + 1

local function randInt(max)
    if not max or max < 1 then return 1 end
    -- Lehmer RNG: los productos quedan dentro de la precision de un double.
    rngState = (rngState * 48271) % 2147483647
    local value = math.floor(rngState / 65536)
    return (value % max) + 1
end

local function clampVolume(value)
    value = tonumber(value) or DEFAULT_VOLUME
    if value < 0 then value = 0 end
    if value > 1 then value = 1 end
    return value
end

local function newState()
    return {
        station = 1,
        track = 1,
        trackChosen = false,
        playing = false,
        volume = DEFAULT_VOLUME,
        muted = false,
        artist = "",
        genreMode = ArgenRadio.MODE_RANDOM,
        artistMode = ArgenRadio.MODE_RANDOM,
        history = {},
        revision = 0,
    }
end

local function deviceKey(device, deviceType)
    if not device then return nil end

    if deviceType == "VehiclePart" then
        local vehicle = device:getVehicle()
        if not vehicle then return nil end
        return "veh:" .. tostring(vehicle:getId())
    elseif deviceType == "IsoObject" then
        local index = 0
        if device.getObjectIndex then
            index = device:getObjectIndex()
        end
        return "iso:" .. tostring(index)
            .. ":" .. tostring(device:getX())
            .. ":" .. tostring(device:getY())
            .. ":" .. tostring(device:getZ())
    elseif deviceType == "InventoryItem" then
        return "item:" .. tostring(device:getID())
    end

    return nil
end

-- Etapa 5: la radio del auto se sincroniza por el servidor. Las radios de
-- casa y las portatiles siguen siendo locales por ahora.
local function shouldSync(deviceType)
    return deviceType == "VehiclePart"
        and isMultiplayer() == true
        and ArgenRadio.Net ~= nil
        and ArgenRadio.Net.isActive()
end

local function vehicleIdOf(device)
    local vehicle = device and device.getVehicle and device:getVehicle() or nil
    return vehicle and vehicle:getId() or nil
end

local function getTargetPos(device, deviceType, player)
    if deviceType == "VehiclePart" then
        local vehicle = device:getVehicle()
        if vehicle then
            return vehicle:getX(), vehicle:getY(), vehicle:getZ()
        end
    elseif deviceType == "IsoObject" then
        return device:getX() + 0.5, device:getY() + 0.5, device:getZ()
    elseif deviceType == "InventoryItem" and player then
        return player:getX(), player:getY(), player:getZ()
    end
    return nil
end

local function getEmitter(device, deviceType, player)
    if deviceType == "VehiclePart" then
        local vehicle = device:getVehicle()
        if not vehicle then return nil end
        return vehicle:getEmitter()
    end

    local x, y, z = getTargetPos(device, deviceType, player)
    if not x then return nil end
    return getWorld():getFreeEmitter(x, y, z)
end

local function isEquipped(player, item)
    if not player or not item then return false end
    return player:getPrimaryHandItem() == item
        or player:getSecondaryHandItem() == item
        or player:getClothingItem_Back() == item
end

function Audio.getState(device, deviceType)
    local key = deviceKey(device, deviceType)
    if not key then return newState() end

    local state = states[key]
    if not state then
        state = newState()
        states[key] = state
    end
    return state
end

function Audio.isPlaying(device, deviceType)
    local key = deviceKey(device, deviceType)
    if not key then return false end
    return sessions[key] ~= nil
end

function Audio.stopLocal(device, deviceType)
    local key = deviceKey(device, deviceType)
    if not key then return false end

    local session = sessions[key]
    if session then
        if session.emitter then
            session.emitter:stopSound(session.soundID)
        end
        sessions[key] = nil
    end

    local state = Audio.getState(device, deviceType)
    state.playing = false
    return true
end

-- Devuelve true si arranco, o false + motivo si no.
-- track es opcional: si no viene, se elige segun el ambito y el modo.
function Audio.playLocal(player, device, deviceType, station, volume, track)
    if not device then
        return false, "No hay dispositivo"
    end

    local key = deviceKey(device, deviceType)
    if not key then
        return false, "Dispositivo no soportado"
    end

    local state = Audio.getState(device, deviceType)
    local _, stationIndex = ArgenRadio.getStation(station or state.station)

    -- Cambiar de emisora descarta el artista y el historial del anterior.
    if stationIndex ~= state.station then
        state.station = stationIndex
        state.artist = ""
        state.history = {}
    end

    local tracks = ArgenRadio.getStationTracks(stationIndex)
    local count = #tracks
    if count == 0 then
        state.playing = false
        return false, "La emisora no tiene temas"
    end

    volume = clampVolume(volume or state.volume)

    track = tonumber(track)
    if track then
        track = math.floor(track)
        if track < 1 then track = 1 end
        if track > count then track = ((track - 1) % count) + 1 end
    else
        track = ArgenRadio.Playlist.pickStart(state, randInt)
    end
    if not track then
        state.playing = false
        return false, "La emisora no tiene temas"
    end

    local soundName = tracks[track] and tracks[track].sound
    if not soundName then
        state.playing = false
        return false, "Falta el sound script de la emisora " .. tostring(stationIndex)
    end

    -- Cortar lo que hubiera sonando en este mismo dispositivo.
    local previous = sessions[key]
    if previous then
        if previous.emitter then
            previous.emitter:stopSound(previous.soundID)
        end
        sessions[key] = nil
    end

    local emitter = getEmitter(device, deviceType, player)
    if not emitter then
        state.playing = false
        return false, "El dispositivo no tiene audio disponible"
    end

    local soundID = emitter:playSound(soundName)
    if not soundID or soundID == 0 then
        state.playing = false
        return false, "No se pudo reproducir " .. tostring(soundName)
    end

    local actualVolume = state.muted and 0 or volume
    emitter:setVolume(soundID, actualVolume)

    sessions[key] = {
        key = key,
        device = device,
        deviceType = deviceType,
        player = player,
        emitter = emitter,
        soundID = soundID,
        soundName = soundName,
        volume = actualVolume,
        station = stationIndex,
        track = track,
        startMs = getTimestampMs and getTimestampMs() or 0,
    }

    state.playing = true
    state.station = stationIndex
    state.track = track
    state.trackChosen = true
    state.volume = volume
    print("[ArgenRadio] Reproduciendo " .. tostring(soundName)
        .. " (emisora " .. tostring(stationIndex) .. ", tema "
        .. tostring(track) .. "/" .. tostring(count) .. ")")
    return true
end

-- Cambia de emisora. Si estaba sonando, arranca con un tema del nuevo
-- genero segun el modo del genero (aleatorio o fila).
function Audio.setStationLocal(player, device, deviceType, station)
    if not device then return false, "No hay dispositivo" end

    local state = Audio.getState(device, deviceType)
    local _, stationIndex = ArgenRadio.getStation(station or state.station)
    if stationIndex == state.station and state.trackChosen then
        return true
    end

    state.station = stationIndex
    state.artist = ""
    state.track = ArgenRadio.Playlist.pickStart(state, randInt)
    state.trackChosen = state.track ~= nil

    if state.playing and state.track then
        return Audio.playLocal(
            player, device, deviceType, stationIndex, state.volume, state.track)
    end
    return true
end

-- Elige "Todo el genero" (artistId = "") o un artista puntual. Si estaba
-- sonando, arranca un tema del nuevo ambito; si no, solo deja elegido.
function Audio.setScopeLocal(player, device, deviceType, artistId)
    if not device then return false, "No hay dispositivo" end

    local state = Audio.getState(device, deviceType)
    artistId = tostring(artistId or "")
    if not ArgenRadio.isValidArtist(state.station, artistId) then
        artistId = ""
    end
    if state.artist == artistId then return true end

    state.artist = artistId
    state.track = ArgenRadio.Playlist.pickStart(state, randInt)
    state.trackChosen = state.track ~= nil

    if state.playing and state.track then
        return Audio.playLocal(
            player, device, deviceType, state.station, state.volume, state.track)
    end
    return true
end

-- Cambia el modo de un ambito ("genre" o "artist") sin cortar el tema.
function Audio.setModeLocal(device, deviceType, scope, mode)
    local state = Audio.getState(device, deviceType)
    mode = ArgenRadio.normalizeMode(mode, ArgenRadio.MODE_RANDOM)

    if scope == "artist" then
        if state.artistMode ~= mode then
            state.artistMode = mode
            state.history = {}
        end
    else
        if state.genreMode ~= mode then
            state.genreMode = mode
            state.history = {}
        end
    end
    return mode
end

-- Reproduce un tema puntual de la emisora (clic en la lista de canciones).
function Audio.selectTrackLocal(player, device, deviceType, track)
    if not device then return false, "No hay dispositivo" end

    local state = Audio.getState(device, deviceType)
    local tracks = ArgenRadio.getStationTracks(state.station)
    if #tracks == 0 then return false, "La emisora no tiene temas" end

    local _, trackIndex = ArgenRadio.getTrack(state.station, track)
    state.track = trackIndex
    state.trackChosen = true
    state.history = {}

    if state.playing then
        return Audio.playLocal(
            player, device, deviceType, state.station, state.volume, trackIndex)
    end
    return true
end

-- Cambia de tema dentro del ambito actual, respetando el modo.
-- delta = 1 (siguiente) o -1 (anterior). Si estaba sonando, lo reproduce.
function Audio.changeTrackLocal(player, device, deviceType, delta)
    if not device then return false, "No hay dispositivo" end

    local state = Audio.getState(device, deviceType)
    local track = ArgenRadio.Playlist.step(state, delta, randInt)
    if not track then return false, "La emisora no tiene temas" end

    state.track = track
    state.trackChosen = true

    if state.playing then
        return Audio.playLocal(
            player, device, deviceType, state.station, state.volume, track)
    end
    return true
end

-- Atajos: el avance automatico y el boton "Tema siguiente".
function Audio.nextTrack(player, device, deviceType)
    return Audio.changeTrack(player, device, deviceType, 1)
end

function Audio.prevTrack(player, device, deviceType)
    return Audio.changeTrack(player, device, deviceType, -1)
end

function Audio.setVolumeLocal(device, deviceType, volume)
    volume = clampVolume(volume)

    local state = Audio.getState(device, deviceType)
    state.volume = volume

    local key = deviceKey(device, deviceType)
    local session = key and sessions[key] or nil
    if session then
        local actualVolume = state.muted and 0 or volume
        session.volume = actualVolume
        session.emitter:setVolume(session.soundID, actualVolume)
    end

    return volume
end

function Audio.setMutedLocal(device, deviceType, muted)
    local state = Audio.getState(device, deviceType)
    state.muted = muted and true or false

    local key = deviceKey(device, deviceType)
    local session = key and sessions[key] or nil
    if session then
        local actualVolume = state.muted and 0 or state.volume
        session.volume = actualVolume
        session.emitter:setVolume(session.soundID, actualVolume)
    end

    return state.muted
end

-- Aplica el estado que manda el servidor. No reenvia comandos: solo
-- recrea o ajusta la sesion local de audio del vehiculo.
function Audio.applyRemoteState(vehicleId, data)
    if not data then return false end

    local vehicle = nil
    if getVehicleById then
        vehicle = getVehicleById(vehicleId)
    end
    if not vehicle then
        local cell = getCell and getCell() or nil
        local vehicles = cell and cell:getVehicles() or nil
        if not vehicles then return false end
        for i = 1, vehicles:size() do
            local candidate = vehicles:get(i - 1)
            if candidate and candidate:getId() == vehicleId then
                vehicle = candidate
                break
            end
        end
    end
    if not vehicle then return false end

    local part = vehicle:getPartById("Radio")
    if not part then return false end

    local state = Audio.getState(part, "VehiclePart")
    local _, stationIndex = ArgenRadio.getStation(data.station or state.station)
    local artist = tostring(data.artist or "")
    if not ArgenRadio.isValidArtist(stationIndex, artist) then
        artist = ""
    end
    local _, trackIndex = ArgenRadio.getTrack(stationIndex, data.track or state.track)
    local volume = clampVolume(data.volume or state.volume)
    local muted = data.muted == true
    local on = data.on == true

    state.station = stationIndex
    state.artist = artist
    state.track = trackIndex
    state.trackChosen = true
    state.volume = volume
    state.muted = muted
    state.genreMode = ArgenRadio.normalizeMode(data.genreMode, state.genreMode)
    state.artistMode = ArgenRadio.normalizeMode(data.artistMode, state.artistMode)
    state.history = {}
    state.revision = tonumber(data.revision) or state.revision or 0

    local key = deviceKey(part, "VehiclePart")
    local session = key and sessions[key] or nil

    if not on then
        if session then
            Audio.stopLocal(part, "VehiclePart")
        end
        state.playing = false
        return true
    end

    local soundName = ArgenRadio.getTrackSound(stationIndex, trackIndex)
    if not soundName then return false end

    -- Mismo tema: solo cambia volumen, mute, ambito o modo; no reiniciar.
    -- Excepcion: si el tema ya termino y el servidor lo volvio a elegir
    -- (ambito de un solo tema), hay que reiniciar el clip.
    if session and session.soundName == soundName then
        local actualVolume = muted and 0 or volume
        session.volume = actualVolume
        if session.emitter and session.soundID then
            session.emitter:setVolume(session.soundID, actualVolume)
            if not session.emitter:isPlaying(session.soundID) then
                local now = getTimestampMs and getTimestampMs() or 0
                if now - (session.startMs or 0) > ADVANCE_GRACE_MS then
                    Audio.stopLocal(part, "VehiclePart")
                    return Audio.playLocal(
                        nil, part, "VehiclePart", stationIndex, volume, trackIndex)
                end
            end
        end
        state.playing = true
        return true
    end

    if session then
        Audio.stopLocal(part, "VehiclePart")
    end
    return Audio.playLocal(nil, part, "VehiclePart", stationIndex, volume, trackIndex)
end

---------------------------------------------------------------
-- API publica: en multijugador manda el comando al servidor y espera el
-- estado autoritativo. En un solo jugador ejecuta todo localmente.
---------------------------------------------------------------

function Audio.play(player, device, deviceType, station, volume, track)
    if shouldSync(deviceType) then
        local vehicleId = vehicleIdOf(device)
        if not vehicleId then return false, "No hay dispositivo" end
        local state = Audio.getState(device, deviceType)
        ArgenRadio.Net.send("play", {
            vehicle = vehicleId,
            station = station,
            track = track,
            volume = volume,
            artist = state.artist or "",
        })
        return true
    end
    return Audio.playLocal(player, device, deviceType, station, volume, track)
end

function Audio.stop(device, deviceType)
    if shouldSync(deviceType) then
        local vehicleId = vehicleIdOf(device)
        Audio.stopLocal(device, deviceType)
        if vehicleId then
            ArgenRadio.Net.send("stop", { vehicle = vehicleId })
        end
        return true
    end
    return Audio.stopLocal(device, deviceType)
end

function Audio.setStation(player, device, deviceType, station)
    if shouldSync(deviceType) then
        local vehicleId = vehicleIdOf(device)
        if not vehicleId then return false, "No hay dispositivo" end
        ArgenRadio.Net.send("station", { vehicle = vehicleId, station = station })
        return true
    end
    return Audio.setStationLocal(player, device, deviceType, station)
end

function Audio.setScope(player, device, deviceType, artistId)
    if shouldSync(deviceType) then
        local vehicleId = vehicleIdOf(device)
        if not vehicleId then return false, "No hay dispositivo" end
        ArgenRadio.Net.send("scope", {
            vehicle = vehicleId,
            artist = tostring(artistId or ""),
        })
        return true
    end
    return Audio.setScopeLocal(player, device, deviceType, artistId)
end

function Audio.setMode(player, device, deviceType, scope, mode)
    if shouldSync(deviceType) then
        local vehicleId = vehicleIdOf(device)
        if not vehicleId then return false, "No hay dispositivo" end
        ArgenRadio.Net.send("mode", {
            vehicle = vehicleId,
            scope = scope,
            mode = mode,
        })
        return true
    end
    return Audio.setModeLocal(device, deviceType, scope, mode)
end

function Audio.selectTrack(player, device, deviceType, track)
    if shouldSync(deviceType) then
        local vehicleId = vehicleIdOf(device)
        if not vehicleId then return false, "No hay dispositivo" end
        ArgenRadio.Net.send("select", {
            vehicle = vehicleId,
            track = track,
        })
        return true
    end
    return Audio.selectTrackLocal(player, device, deviceType, track)
end

function Audio.changeTrack(player, device, deviceType, delta)
    if shouldSync(deviceType) then
        local vehicleId = vehicleIdOf(device)
        if not vehicleId then return false, "No hay dispositivo" end
        ArgenRadio.Net.send("track", { vehicle = vehicleId, delta = delta })
        return true
    end
    return Audio.changeTrackLocal(player, device, deviceType, delta)
end

function Audio.setVolume(device, deviceType, volume)
    local ok = Audio.setVolumeLocal(device, deviceType, volume)
    if shouldSync(deviceType) then
        local vehicleId = vehicleIdOf(device)
        if vehicleId then
            ArgenRadio.Net.send("volume", { vehicle = vehicleId, volume = ok })
        end
    end
    return ok
end

function Audio.setMuted(device, deviceType, muted)
    local ok = Audio.setMutedLocal(device, deviceType, muted)
    if shouldSync(deviceType) then
        local vehicleId = vehicleIdOf(device)
        if vehicleId then
            ArgenRadio.Net.send("mute", { vehicle = vehicleId, muted = ok })
        end
    end
    return ok
end

-- Mantiene las sesiones vivas, actualiza la posicion de las portatiles y
-- pasa al tema siguiente cuando termina el actual.
function Audio.update()
    local now = getTimestampMs and getTimestampMs() or 0
    local advance = {}

    for key, session in pairs(sessions) do
        local alive = true

        if session.deviceType == "InventoryItem" then
            if not isEquipped(session.player, session.device) then
                alive = false
            elseif session.player then
                -- La radio portatil sigue al jugador que la tiene puesta.
                session.emitter:setPos(session.player:getX(), session.player:getY(), session.player:getZ())
            end
        elseif session.deviceType == "IsoObject" then
            if not session.device:getSquare() then
                alive = false
            end
        elseif session.deviceType == "VehiclePart" then
            local vehicle = session.device:getVehicle()
            if not vehicle or not vehicle:getSquare() then
                alive = false
            end
        end

        if not alive then
            Audio.stopLocal(session.device, session.deviceType)
        elseif session.emitter and session.soundID then
            if not session.emitter:isPlaying(session.soundID) then
                if now - (session.startMs or 0) > ADVANCE_GRACE_MS then
                    if shouldSync(session.deviceType) then
                        -- Multijugador: pedir el avance una sola vez. El
                        -- servidor acepta al primero que trae la revision.
                        if not session.advanceSent then
                            session.advanceSent = true
                            local vehicleId = vehicleIdOf(session.device)
                            local state = Audio.getState(session.device, session.deviceType)
                            if vehicleId then
                                ArgenRadio.Net.send("advance", {
                                    vehicle = vehicleId,
                                    revision = state.revision or 0,
                                })
                            end
                        end
                    else
                        table.insert(advance, session)
                    end
                end
            end
        end
    end

    -- Fuera del recorrido de sessions: reproducir toca la tabla.
    for i = 1, #advance do
        local session = advance[i]
        -- Si mientras tanto se cambio de tema/emisora, esta sesion ya no vale.
        if session.key and sessions[session.key] == session then
            Audio.nextTrack(session.player, session.device, session.deviceType)
        end
    end
end

Events.OnTick.Add(Audio.update)

print("[ArgenRadio] Motor de audio listo")

-- ArgenRadio - motor de audio del cliente
-- Reproduce la playlist de la emisora elegida en el emitter del dispositivo:
--   * vehiculo  -> emitter propio del vehiculo (sigue sonando al bajarse)
--   * casa      -> emitter libre posicionado en el objeto
--   * portatil  -> emitter libre que sigue al jugador que la lleva
--
-- Etapa 4: cada emisora tiene varios temas. El primero se elige al azar y
-- al terminar uno arranca el siguiente solo. Los botones Tema anterior /
-- Tema siguiente recorren la lista en orden; la emisora se cambia aparte.

ArgenRadio = ArgenRadio or {}
ArgenRadio.Audio = ArgenRadio.Audio or {}

local Audio = ArgenRadio.Audio

local DEFAULT_VOLUME = 0.7
-- Margen para no confundir "todavia no arranco" con "ya termino".
local ADVANCE_GRACE_MS = 1500

-- Estado por dispositivo (emisora, tema, encendido, volumen).
local states = {}
-- Sesiones de audio activas por dispositivo.
local sessions = {}

-- Generador pseudoaleatorio propio: el Lua de Project Zomboid (Kahlua)
-- no garantiza math.random ni math.randomseed. Con esto el tema inicial
-- cambia en cada partida sin depender de esas funciones.
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

local function normalizeStation(index)
    local n = #ArgenRadio.STATIONS
    if n == 0 then return 1 end
    index = tonumber(index) or 1
    index = math.floor(index)
    if index < 1 then index = 1 end
    if index > n then index = ((index - 1) % n) + 1 end
    return index
end

-- Devuelve otro tema al azar, evitando repetir el actual.
local function pickRandomTrack(state, count)
    if count <= 1 then return 1 end
    local current = state and state.track
    local index = randInt(count)
    if index == current then
        index = (index % count) + 1
    end
    return index
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
    if not key then
        return {
            station = 1, track = 1, trackChosen = false, playing = false,
            volume = DEFAULT_VOLUME, muted = false,
        }
    end

    local state = states[key]
    if not state then
        state = {
            station = 1, track = 1, trackChosen = false, playing = false,
            volume = DEFAULT_VOLUME, muted = false,
        }
        states[key] = state
    end
    return state
end

function Audio.isPlaying(device, deviceType)
    local key = deviceKey(device, deviceType)
    if not key then return false end
    return sessions[key] ~= nil
end

function Audio.stop(device, deviceType)
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
-- track es opcional: si no viene, se elige uno al azar.
function Audio.play(player, device, deviceType, station, volume, track)
    if not device then
        return false, "No hay dispositivo"
    end

    local key = deviceKey(device, deviceType)
    if not key then
        return false, "Dispositivo no soportado"
    end

    local state = Audio.getState(device, deviceType)
    station = normalizeStation(station or state.station)

    local tracks = ArgenRadio.getStationTracks(station)
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
        track = pickRandomTrack(state, count)
    end

    local soundName = tracks[track] and tracks[track].sound
    if not soundName then
        state.playing = false
        return false, "Falta el sound script de la emisora " .. tostring(station)
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
        station = station,
        track = track,
        startMs = getTimestampMs and getTimestampMs() or 0,
    }

    state.playing = true
    state.station = station
    state.track = track
    state.trackChosen = true
    state.volume = volume
    print("[ArgenRadio] Reproduciendo " .. tostring(soundName)
        .. " (emisora " .. tostring(station) .. ", tema "
        .. tostring(track) .. "/" .. tostring(count) .. ")")
    return true
end

-- Cambia de emisora. Si estaba sonando, reinicia con un tema al azar.
function Audio.setStation(player, device, deviceType, station)
    if not device then return false, "No hay dispositivo" end

    local state = Audio.getState(device, deviceType)
    local count = #ArgenRadio.STATIONS
    if count == 0 then return false, "No hay emisoras" end

    station = normalizeStation(station or state.station)
    state.station = station

    local tracks = ArgenRadio.getStationTracks(station)
    state.track = pickRandomTrack(state, #tracks)
    state.trackChosen = true

    if state.playing then
        return Audio.play(
            player, device, deviceType, station, state.volume, state.track)
    end
    return true
end

-- Cambia de tema dentro de la misma emisora, en orden y dando la vuelta.
-- delta = 1 (siguiente) o -1 (anterior). Si estaba sonando, lo reproduce.
function Audio.changeTrack(player, device, deviceType, delta)
    if not device then return false, "No hay dispositivo" end

    local state = Audio.getState(device, deviceType)
    local tracks = ArgenRadio.getStationTracks(state.station)
    local count = #tracks
    if count == 0 then return false, "La emisora no tiene temas" end

    delta = tonumber(delta) or 1
    if delta < 0 then delta = -1 else delta = 1 end

    local current = state.track or 1
    local track = ((current - 1 + delta) % count) + 1
    state.track = track
    state.trackChosen = true

    if state.playing then
        return Audio.play(
            player, device, deviceType, state.station, state.volume, track)
    end
    return true
end

-- Atajos: el avance automatico y el boton "Tema siguiente" van al siguiente.
function Audio.nextTrack(player, device, deviceType)
    return Audio.changeTrack(player, device, deviceType, 1)
end

function Audio.prevTrack(player, device, deviceType)
    return Audio.changeTrack(player, device, deviceType, -1)
end

function Audio.setVolume(device, deviceType, volume)
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

function Audio.setMuted(device, deviceType, muted)
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
            Audio.stop(session.device, session.deviceType)
        elseif session.emitter and session.soundID then
            if not session.emitter:isPlaying(session.soundID) then
                if now - (session.startMs or 0) > ADVANCE_GRACE_MS then
                    table.insert(advance, session)
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

-- ArgenRadio - motor de audio del cliente
-- Reproduce la playlist de la emisora elegida en el emitter del dispositivo:
--   * vehiculo  -> emitter propio del vehiculo (sigue sonando al bajarse)
--   * casa      -> emitter libre posicionado en el objeto
--   * portatil  -> emitter libre que sigue al jugador que la lleva
--
-- Etapa 4: cada emisora tiene varios temas. El primero se elige al azar y
-- al terminar uno arranca el siguiente solo. Los botones Tema anterior /
-- Tema siguiente recorren la lista en orden; la emisora se cambia aparte.
--
-- Etapa 5: la radio del vehiculo pasa por el servidor (ver ArgenRadio_Net.lua
-- y ArgenRadio_Server.lua). Las funciones *Local son el motor de siempre;
-- la API publica decide entre local y multijugador.

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
-- track es opcional: si no viene, se elige uno al azar.
function Audio.playLocal(player, device, deviceType, station, volume, track)
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
function Audio.setStationLocal(player, device, deviceType, station)
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
        return Audio.playLocal(
            player, device, deviceType, station, state.volume, state.track)
    end
    return true
end

-- Cambia de tema dentro de la misma emisora, en orden y dando la vuelta.
-- delta = 1 (siguiente) o -1 (anterior). Si estaba sonando, lo reproduce.
function Audio.changeTrackLocal(player, device, deviceType, delta)
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
        return Audio.playLocal(
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
    local _, trackIndex = ArgenRadio.getTrack(stationIndex, data.track or state.track)
    local volume = clampVolume(data.volume or state.volume)
    local muted = data.muted == true
    local on = data.on == true

    state.station = stationIndex
    state.track = trackIndex
    state.trackChosen = true
    state.volume = volume
    state.muted = muted
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

    -- Mismo tema: solo cambia volumen o mute, no reiniciar el audio.
    if session and session.soundName == soundName then
        local actualVolume = muted and 0 or volume
        session.volume = actualVolume
        if session.emitter and session.soundID then
            session.emitter:setVolume(session.soundID, actualVolume)
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
        ArgenRadio.Net.send("play", {
            vehicle = vehicleId,
            station = station,
            track = track,
            volume = volume,
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

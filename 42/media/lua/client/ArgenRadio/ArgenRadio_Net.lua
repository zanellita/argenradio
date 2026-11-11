-- ArgenRadio - red del cliente (etapa 5)
-- Envia los comandos de la radio del auto al servidor autoritativo y
-- aplica el estado que el servidor retransmite.

ArgenRadio = ArgenRadio or {}
ArgenRadio.Net = ArgenRadio.Net or {}

local Net = ArgenRadio.Net

local MODULE = "ArgenRadio"

function Net.isActive()
    return isMultiplayer() == true
end

local function deviceVehicleId(device)
    if not device then return nil end
    local vehicle = device.getVehicle and device:getVehicle() or nil
    return vehicle and vehicle:getId() or nil
end

function Net.send(command, args)
    if not Net.isActive() then return false end
    local player = getPlayer()
    if not player then return false end
    sendClientCommand(player, MODULE, command, args or {})
    return true
end

-- Pide el estado actual del vehiculo. No exige estar cerca.
function Net.request(player, device)
    local vehicleId = deviceVehicleId(device)
    if not vehicleId then return false end
    return Net.send("request", { vehicle = vehicleId })
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE or command ~= "state" then return end
    if not args then return end

    local vehicleId = tonumber(args.vehicle)
    if not vehicleId then return end
    if not (ArgenRadio.Audio and ArgenRadio.Audio.applyRemoteState) then return end

    ArgenRadio.Audio.applyRemoteState(vehicleId, args)
end)

print("[ArgenRadio] Red del cliente lista (etapa 5)")

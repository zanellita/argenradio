-- ArgenRadio - ventana de radio (etapas 4.1, 5 y biblioteca 0.6)
-- Rediseño estilo vanilla: un modulo principal con pantalla de sintonia
-- (estetica, sin funcion real) y un segundo modulo plegable "Generos".
-- Se aplica a radios de vehiculo, de casa y portatiles.
-- No toca televisores ni walkie-talkies (two-way).
--
-- El modulo "Generos" es genero -> artista -> canciones. Hay dos estados
-- separados:
--   * "seleccionado" es solo de esta ventana: clic en genero, artista o
--     cancion mueve el resaltado y las listas, sin tocar el audio;
--   * "sonando" es el estado del motor (y el que viaja por red): se marca
--     con un triangulito y la etiqueta "Sonando".
-- El audio solo cambia con el boton "Reproducir" que esta debajo de la
-- lista de canciones; "Tema anterior/siguiente", volumen y encendido siguen
-- actuando sobre lo que esta sonando, no sobre la seleccion.
-- Al cerrar y reabrir la ventana, la seleccion vuelve a lo que esta sonando.

require "ISUI/ISScrollingListBox"

local UI_BORDER_SPACING = 10
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_LARGE = getTextManager():getFontHeight(UIFont.Large)
local BUTTON_HGT = FONT_HGT_SMALL + 8
local WINDOW_MIN_WIDTH = 560
local LIB_LIST_H = 132
local LIB_GAP = 6
local MHZ_WIDTH = getTextManager():MeasureStringX(UIFont.Small, "MHz")
local SONANDO_WIDTH = getTextManager():MeasureStringX(UIFont.Small, "Sonando")

-- Paleta de la pantalla de sintonia: fondo liso + acento celeste argentino.
local LCD_BG      = { r = 0.078, g = 0.086, b = 0.102 } -- #14161A
local TEXT_MAIN   = { r = 0.949, g = 0.949, b = 0.949 } -- #F2F2F2
local TEXT_DIM    = { r = 0.541, g = 0.561, b = 0.596 } -- #8A8F98
local RULE        = { r = 0.196, g = 0.216, b = 0.251 } -- linea tenue
local ACCENT      = { r = 0.455, g = 0.675, b = 0.875 } -- celeste bandera
local ACCENT_SOFT = { r = 0.694, g = 0.827, b = 0.910 } -- celeste claro

local function stationTitle(station)
    return (station.freq or "--.-") .. "   " .. (station.nombre or "ArgenRadio")
end

-- Recorta un texto para que no se meta debajo del contador de temas.
local function fitText(text, maxWidth)
    text = tostring(text or "")
    if maxWidth <= 0 then return "" end
    local tm = getTextManager()
    if tm:MeasureStringX(UIFont.Small, text) <= maxWidth then return text end

    local ellipsis = "..."
    local available = maxWidth - tm:MeasureStringX(UIFont.Small, ellipsis)
    if available <= 0 then return ellipsis end

    local lo, hi = 0, #text
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if tm:MeasureStringX(UIFont.Small, string.sub(text, 1, mid)) <= available then
            lo = mid
        else
            hi = mid - 1
        end
    end
    -- No cortar en medio de un caracter UTF-8 (acentos, enie).
    while lo > 0 do
        local byte = string.byte(text, lo + 1)
        if not byte or byte < 128 or byte > 191 then break end
        lo = lo - 1
    end
    return string.sub(text, 1, lo) .. ellipsis
end

-- El titulo del dial se recorta con una busqueda binaria de mediciones; se
-- cachea para no repetirla en cada fotograma. Solo cambia cuando cambia el
-- tema o el ancho disponible.
local function fitTextCached(panel, text, maxWidth)
    local key = tostring(text) .. "|" .. tostring(math.floor(maxWidth))
    if panel.fitKey == key then return panel.fitResult end
    panel.fitKey = key
    panel.fitResult = fitText(text, maxWidth)
    return panel.fitResult
end

local function formatTime(ms)
    local totalSec = math.floor((tonumber(ms) or 0) / 1000)
    if totalSec < 0 then totalSec = 0 end
    local min = math.floor(totalSec / 60)
    local sec = totalSec % 60
    return tostring(min) .. ":" .. (sec < 10 and "0" or "") .. tostring(sec)
end

-- Datos del dial que solo cambian al cambiar emisora, artista o tema.
local function dialInfo(panel, index, artistId, trackIndex)
    local key = tostring(index) .. "|" .. tostring(artistId) .. "|" .. tostring(trackIndex)
    if panel.dialKey == key then return panel.dialInfo end

    local station = ArgenRadio.getStation(index) or {}
    local scopeTracks = ArgenRadio.getScopeTracks(index, artistId)
    local info = {
        station = station,
        freq = tostring(station.freq or "--.-"),
        name = tostring(station.nombre or "ArgenRadio"),
        scopeName = ArgenRadio.getScopeName(index, artistId),
        trackTitle = ArgenRadio.getTrackTitle(index, trackIndex),
        position = ArgenRadio.getScopePosition(index, artistId, trackIndex),
        total = #scopeTracks,
    }
    panel.dialKey = key
    panel.dialInfo = info
    return info
end

-- Fraccion 0..1 donde va la marca de la emisora en la escala del dial.
local function dialMarkerT(panel, station, index)
    local freqNum = tonumber(station.freq)
    local cacheKey = tostring(station.freq) .. "|" .. tostring(index)
    if panel.markerKey == cacheKey then return panel.markerT end

    local minFreq, maxFreq = ArgenRadio.getFrequencyRange()
    local count = #ArgenRadio.getStations()
    local t = 0.5
    if minFreq and maxFreq and maxFreq > minFreq and freqNum then
        t = (freqNum - minFreq) / (maxFreq - minFreq)
    elseif count > 1 then
        t = (index - 1) / (count - 1)
    end
    panel.markerKey = cacheKey
    panel.markerT = t
    return t
end

local function installArgenRadioWindow()
    if not ISRadioWindow or ISRadioWindow.argenRadioHooked then return end
    if not RWMPanel or not ISVolumeBar or not ISSpeakerButton then
        print("[ArgenRadio] No se encontro la ventana de radio vanilla; no se instala el panel")
        return
    end
    ISRadioWindow.argenRadioHooked = true

    ---------------------------------------------------------------
    -- Pantalla de sintonia dibujada (solo estetica)
    ---------------------------------------------------------------
    -- Corchea chiquita dibujada a mano: el font del juego no trae "♪".
    local function drawNote(panel, nx, ny, r, g, b, a)
        panel:drawRect(nx + 1, ny, 3, 1, a, r, g, b)
        panel:drawRect(nx, ny + 1, 5, 2, a, r, g, b)
        panel:drawRect(nx + 1, ny + 3, 3, 1, a, r, g, b)
        panel:drawRect(nx + 4, ny - 7, 1, 8, a, r, g, b)
        panel:drawRect(nx + 5, ny - 7, 2, 1, a, r, g, b)
        panel:drawRect(nx + 6, ny - 6, 2, 1, a, r, g, b)
        panel:drawRect(nx + 7, ny - 5, 1, 2, a, r, g, b)
    end

    local function drawTuningDial(panel)
        local x, y, w, h = panel.dialX, panel.dialY, panel.dialW, panel.dialH

        -- Pantalla de un solo color, sin grilla ni marco.
        panel:drawRect(x, y, w, h, 1.0, LCD_BG.r, LCD_BG.g, LCD_BG.b)

        local pad = 12
        local left = x + pad
        local right = x + w - pad

        local state = panel.state
        local playing = state and state.playing and true or false
        local muted = state and state.muted and true or false
        local index = panel.stationIndex or 1
        local artistId = state and state.artist or ""
        local trackIndex = state and state.track or 1

        -- Emisora, artista, tema, posicion y titulo se cachean: solo cambian
        -- cuando cambia algo de eso, no en cada fotograma.
        local info = dialInfo(panel, index, artistId, trackIndex)
        local freq, name = info.freq, info.name

        -- Arriba: punto de estado + FM a la izquierda, frecuencia + MHz a la derecha.
        local topY = y + 8
        local fmY = topY + math.floor((FONT_HGT_LARGE - FONT_HGT_SMALL) / 2)

        local dotS = 6
        local dotY = fmY + math.floor((FONT_HGT_SMALL - dotS) / 2)
        if playing then
            panel:drawRectBorder(left - 1, dotY - 1, dotS + 2, dotS + 2,
                0.40, ACCENT.r, ACCENT.g, ACCENT.b)
            panel:drawRect(left, dotY, dotS, dotS, muted and 0.55 or 1.0,
                ACCENT.r, ACCENT.g, ACCENT.b)
        else
            panel:drawRect(left, dotY, dotS, dotS, 1.0,
                RULE.r, RULE.g, RULE.b)
        end

        panel:drawText("FM", left + dotS + 8, fmY,
            TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1.0, UIFont.Small)

        panel:drawText("MHz", right - MHZ_WIDTH, fmY,
            TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1.0, UIFont.Small)
        panel:drawTextRight(freq, right - MHZ_WIDTH - 6, topY,
            ACCENT_SOFT.r, ACCENT_SOFT.g, ACCENT_SOFT.b, 1.0, UIFont.Large)

        -- Centro: nombre de la emisora y ambito actual (artista o genero).
        local nameY = topY + FONT_HGT_LARGE + 6
        panel:drawTextCentre(name, x + w / 2, nameY,
            TEXT_MAIN.r, TEXT_MAIN.g, TEXT_MAIN.b, 1.0, UIFont.Large)

        local scopeColor = (artistId ~= "") and ACCENT_SOFT or TEXT_DIM
        panel:drawTextCentre(info.scopeName, x + w / 2, nameY + FONT_HGT_LARGE + 1,
            scopeColor.r, scopeColor.g, scopeColor.b, 1.0, UIFont.Small)

        -- Marcador de reproduccion: posicion dentro del tema y duracion.
        local session = nil
        if playing and panel.device and ArgenRadio.Audio
            and ArgenRadio.Audio.getPlayback then
            session = ArgenRadio.Audio.getPlayback(panel.device, panel.deviceType)
        end
        local durationMs = session and tonumber(session.durationMs) or nil
        local elapsedMs = nil
        if durationMs and durationMs > 0 then
            local now = getTimestampMs and getTimestampMs() or 0
            elapsedMs = now - (session.startMs or now)
            if elapsedMs < 0 then elapsedMs = 0 end
            if elapsedMs > durationMs then elapsedMs = durationMs end
        end

        -- Abajo: tema actual a la izquierda y tiempo/posicion/modo a la derecha.
        local ruleY = y + h - 10
        local trackY = ruleY - FONT_HGT_SMALL - 8
        local mode = ArgenRadio.getActiveMode(state)
        local modeLabel = (mode == ArgenRadio.MODE_LIST) and "En fila" or "Aleatorio"
        local rightText = tostring(info.position) .. "/" .. tostring(info.total)
        if elapsedMs then
            rightText = formatTime(elapsedMs) .. " / " .. formatTime(durationMs)
                .. "  " .. rightText
        end
        rightText = rightText .. "  " .. modeLabel

        local rightW
        if panel.rightText == rightText then
            rightW = panel.rightW
        else
            panel.rightText = rightText
            rightW = getTextManager():MeasureStringX(UIFont.Small, rightText)
            panel.rightW = rightW
        end

        local trackTitle = fitTextCached(panel, info.trackTitle,
            (right - left) - 12 - rightW - 10)

        local noteY = trackY + FONT_HGT_SMALL - 6
        drawNote(panel, left, noteY, ACCENT.r, ACCENT.g, ACCENT.b, 0.95)
        panel:drawText(trackTitle, left + 12, trackY,
            TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1.0, UIFont.Small)
        panel:drawTextRight(rightText, right, trackY,
            TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1.0, UIFont.Small)

        -- Barra de progreso fina, justo arriba de la escala de frecuencia.
        if elapsedMs then
            local barY = ruleY - 6
            local barW = right - left
            panel:drawRect(left, barY, barW, 2, 0.55,
                RULE.r, RULE.g, RULE.b)
            local fillW = math.floor(barW * (elapsedMs / durationMs) + 0.5)
            if fillW > 0 then
                panel:drawRect(left, barY, fillW, 2, 1.0,
                    ACCENT.r, ACCENT.g, ACCENT.b)
            end
        end

        -- Linea fina inferior (escala) y marca celeste de la emisora.
        panel:drawRect(left, ruleY, right - left, 1, 1.0,
            RULE.r, RULE.g, RULE.b)

        -- La marca se ubica segun la frecuencia, como un dial real.
        local scaleL, scaleR = left + 4, right - 4
        local t = dialMarkerT(panel, info.station, index)
        local markerX = math.floor(scaleL + t * (scaleR - scaleL))
        panel:drawRect(markerX - 2, ruleY - 3, 5, 7, 0.18,
            ACCENT.r, ACCENT.g, ACCENT.b)
        panel:drawRect(markerX, ruleY - 4, 2, 9, 1.0,
            ACCENT.r, ACCENT.g, ACCENT.b)
    end

    ---------------------------------------------------------------
    -- Modulo principal: sintonia + controles + volumen
    ---------------------------------------------------------------
    RWMArgenRadio = RWMPanel:derive("RWMArgenRadio")

    function RWMArgenRadio:createChildren()
        local avail = self.width - UI_BORDER_SPACING * 2 - 2

        self.dialX = UI_BORDER_SPACING + 1
        self.dialY = UI_BORDER_SPACING + 1
        self.dialW = avail
        self.dialH = math.max(124, FONT_HGT_LARGE * 2 + FONT_HGT_SMALL + 70)

        self.controlsY = self.dialY + self.dialH + 10

        local gap = 6
        local btnW = math.floor((avail - gap * 2) / 3)
        local x1 = self.dialX
        local x2 = x1 + btnW + gap
        local x3 = x2 + btnW + gap

        self.prevButton = ISButton:new(x1, self.controlsY, btnW, BUTTON_HGT,
            "Tema anterior", self, RWMArgenRadio.onPrev)
        self.prevButton:initialise()
        self.prevButton:setFont(UIFont.Small)
        self:addChild(self.prevButton)

        self.playButton = ISButton:new(x2, self.controlsY, btnW, BUTTON_HGT,
            "Reproducir", self, RWMArgenRadio.onPlay)
        self.playButton:initialise()
        self.playButton:setFont(UIFont.Small)
        self:addChild(self.playButton)

        self.nextButton = ISButton:new(x3, self.controlsY, btnW, BUTTON_HGT,
            "Tema siguiente", self, RWMArgenRadio.onNext)
        self.nextButton:initialise()
        self.nextButton:setFont(UIFont.Small)
        self:addChild(self.nextButton)

        local volY = self.controlsY + BUTTON_HGT + 10
        self.speakerButton = ISSpeakerButton:new(
            x1, volY, BUTTON_HGT, BUTTON_HGT,
            RWMArgenRadio.onSpeakerButton, self)
        self.speakerButton:initialise()
        self:addChild(self.speakerButton)

        local barX = x1 + BUTTON_HGT + gap
        self.volumeBar = ISVolumeBar:new(
            barX, volY, self.width - barX - UI_BORDER_SPACING - 1, BUTTON_HGT,
            RWMArgenRadio.onVolumeChange, self)
        self.volumeBar:initialise()
        self:addChild(self.volumeBar)

        self:setHeight(volY + BUTTON_HGT + UI_BORDER_SPACING)
    end

    function RWMArgenRadio:readFromObject(_player, _deviceObject, _deviceData, _deviceType)
        RWMPanel.readFromObject(self, _player, _deviceObject, _deviceData, _deviceType)

        if not _deviceData then return false end
        -- Los televisores y las radios bidireccionales siguen con la UI vanilla.
        if _deviceData:getIsTelevision() or _deviceData:getIsTwoWay() then
            return false
        end
        -- Si el motor de audio no termino de cargar, no romper la ventana.
        if not (ArgenRadio.Audio and ArgenRadio.Audio.getState) then
            return false
        end

        self.state = ArgenRadio.Audio.getState(_deviceObject, _deviceType)
        self.stationIndex = self.state.station or 1
        self.lastMuted = self.state.muted and true or false
        self.volumeBar:setVolume(math.floor(self.state.volume * self.volumeBar:getVolumeSteps()))
        self.volumeBar:setEnableControls(not self.state.muted)
        self.speakerButton.isMute = self.state.muted and true or false
        self.speakerButton:setEnableControls(true)
        self:refreshControls()

        -- Etapa 5: la radio del auto pide el estado autoritativo al servidor.
        if self.deviceType == "VehiclePart" and ArgenRadio.Net then
            ArgenRadio.Net.request(self.player, self.device)
        end
        return true
    end

    function RWMArgenRadio:clear()
        RWMPanel.clear(self)
        self.state = nil
        self.stationIndex = 1
        self.lastPlaying = nil
        self.lastMuted = nil
    end

    function RWMArgenRadio:refreshControls()
        if not self.state then return end
        if self.playButton then
            -- Encendido/apagado de la radio. La seleccion de temas se
            -- reproduce con el boton "Reproducir" del modulo "Generos".
            self.playButton:setTitle(self.state.playing and "Apagar" or "Encender")
        end
        if self.speakerButton then
            self.speakerButton.isMute = self.state.muted and true or false
        end
        self.stationIndex = self.state.station or 1
    end

    function RWMArgenRadio:changeTrack(delta)
        if not self.device or not self.state then return end
        local ok, err = ArgenRadio.Audio.changeTrack(
            self.player, self.device, self.deviceType, delta)
        if not ok and err then
            print("[ArgenRadio] " .. tostring(err))
            if self.player and HaloTextHelper then
                HaloTextHelper.addBadText(self.player, err)
            end
        end
    end

    function RWMArgenRadio:onPrev()
        self:changeTrack(-1)
    end

    function RWMArgenRadio:onNext()
        self:changeTrack(1)
    end

    function RWMArgenRadio:onPlay()
        if not self.device or not self.state then return end

        if self.state.playing then
            ArgenRadio.Audio.stop(self.device, self.deviceType)
        else
            -- Si ya se eligio un tema en el dial, respetarlo; si no, que el
            -- motor elija segun el ambito y el modo.
            local track = self.state.trackChosen and self.state.track or nil
            local ok, err = ArgenRadio.Audio.play(
                self.player, self.device, self.deviceType,
                self.state.station, self.state.volume, track)
            if not ok and err then
                print("[ArgenRadio] " .. tostring(err))
                if self.player and HaloTextHelper then
                    HaloTextHelper.addBadText(self.player, err)
                end
            end
        end
        self:refreshControls()
    end

    function RWMArgenRadio:onVolumeChange(steps)
        if not self.state then return end
        local volume = steps / self.volumeBar:getVolumeSteps()
        ArgenRadio.Audio.setVolume(self.device, self.deviceType, volume)
    end

    function RWMArgenRadio:onSpeakerButton(isMute)
        if not self.state then return end
        ArgenRadio.Audio.setMuted(self.device, self.deviceType, isMute)
        self.speakerButton.isMute = isMute
        self.volumeBar:setEnableControls(not isMute)
    end

    function RWMArgenRadio:update()
        ISPanel.update(self)
        if not self.device or not self.state then return end

        local now = getTimestampMs and getTimestampMs() or 0
        ArgenRadio._panelActiveMs = now

        -- La sesion nativa no hace falta consultarla en cada fotograma: el
        -- estado ya cambia al reproducir/parar. Con 250 ms alcanza para
        -- detectar finales y cambios que vengan del servidor.
        if now >= (self.nextPlayCheckMs or 0) then
            self.nextPlayCheckMs = now + 250
            local playing = ArgenRadio.Audio.isPlaying(self.device, self.deviceType)
            if self.state.playing ~= playing then
                self.state.playing = playing
            end
        end
        local playing = self.state.playing and true or false
        local station = self.state.station or 1

        -- Volumen y mute tambien pueden venir del otro jugador (etapa 5).
        if self.volumeBar and not self.volumeBar:isDragging() then
            local steps = self.volumeBar:getVolumeSteps()
            local barSteps = math.floor((self.state.volume or 0) * steps)
            if self.volumeBar:getVolume() ~= barSteps then
                self.volumeBar:setVolume(barSteps)
            end
        end
        if self.lastMuted ~= self.state.muted then
            self.lastMuted = self.state.muted and true or false
            self.speakerButton.isMute = self.lastMuted
            self.volumeBar:setEnableControls(not self.lastMuted)
            self:refreshControls()
        end

        if self.stationIndex ~= station or self.lastPlaying ~= playing then
            self.stationIndex = station
            self.lastPlaying = playing
            self:refreshControls()
        end
    end

    function RWMArgenRadio:render()
        ISPanel.render(self)
        drawTuningDial(self)
    end

    function RWMArgenRadio:new(x, y, width, height)
        local o = RWMPanel:new(x, y, width, height)
        setmetatable(o, self)
        self.__index = self
        o.x = x
        o.y = y
        o.width = width
        o.height = height
        o.state = nil
        o.stationIndex = 1
        o.lastPlaying = nil
        o.lastMuted = nil
        o.dialX = 0
        o.dialY = 0
        o.dialW = 0
        o.dialH = 0
        o.controlsY = 0
        return o
    end

    ---------------------------------------------------------------
    -- Modulo plegable: generos, artistas y canciones
    ---------------------------------------------------------------
    -- Triangulo "sonando" dibujado a mano: el font del juego no trae "▶".
    -- El mismo dibujo se usa en las filas y en la etiqueta del encabezado.
    local function drawPlayTriangle(panel, tx, ty, cr, cg, cb, ca)
        panel:drawRect(tx, ty, 2, 1, ca, cr, cg, cb)
        panel:drawRect(tx, ty + 1, 3, 1, ca, cr, cg, cb)
        panel:drawRect(tx, ty + 2, 4, 1, ca, cr, cg, cb)
        panel:drawRect(tx, ty + 3, 4, 1, ca, cr, cg, cb)
        panel:drawRect(tx, ty + 4, 3, 1, ca, cr, cg, cb)
        panel:drawRect(tx, ty + 5, 2, 1, ca, cr, cg, cb)
    end

    -- Lista con marca de "sonando": playingItem es el valor (item.item) de
    -- la fila que esta sonando en este momento, o nil si no corresponde.
    -- La seleccion sigue usando el resaltado normal de ISScrollingListBox,
    -- asi los dos estados se distinguen sin cambiar la lista vanilla.
    ArgenRadioList = ISScrollingListBox:derive("ArgenRadioList")

    function ArgenRadioList:doDrawItem(y, item, alt)
        local nextY = ISScrollingListBox.doDrawItem(self, y, item, alt)
        if self.playingItem ~= nil and item.item == self.playingItem then
            self:drawRect(3, y + 3, 2, item.height - 6, 1.0,
                ACCENT.r, ACCENT.g, ACCENT.b)
            drawPlayTriangle(self, 7,
                y + math.floor((item.height - 6) / 2),
                ACCENT.r, ACCENT.g, ACCENT.b, 1.0)
        end
        return nextY
    end

    -- prerender reducido: recorre solo las filas visibles. La lista vanilla
    -- pasa por los 90 temas en cada fotograma aunque esten fuera de vista;
    -- con altura fija de fila el rango visible sale con una division.
    function ArgenRadioList:prerender()
        local items = self.items
        if items == nil then return end

        local scroll = self:getYScroll()
        local bg = self.backgroundColor
        self:drawRect(0, -scroll, self.width, self.height,
            bg.a, bg.r, bg.g, bg.b)

        local stencilX, stencilY = 0, 0
        local stencilX2, stencilY2 = self.width, self.height
        if self.drawBorder then
            local bc = self.borderColor
            self:drawRectBorder(0, -scroll, self.width, self.height,
                bc.a, bc.r, bc.g, bc.b)
            stencilX, stencilY = 1, 1
            stencilX2, stencilY2 = self.width - 1, self.height - 1
        end
        if self:isVScrollBarVisible() then
            stencilX2 = self.vscroll.x + 3
        end
        if self:parentsHaveScrollChildren() then
            stencilX = self.javaObject:clampToParentX(
                self:getAbsoluteX() + stencilX) - self:getAbsoluteX()
            stencilX2 = self.javaObject:clampToParentX(
                self:getAbsoluteX() + stencilX2) - self:getAbsoluteX()
            stencilY = self.javaObject:clampToParentY(
                self:getAbsoluteY() + stencilY) - self:getAbsoluteY()
            stencilY2 = self.javaObject:clampToParentY(
                self:getAbsoluteY() + stencilY2) - self:getAbsoluteY()
        end
        self:setStencilRect(stencilX, stencilY,
            stencilX2 - stencilX, stencilY2 - stencilY)

        local itemH = self.itemheight
        local total = #items
        local first = math.floor((-scroll) / itemH) + 1
        if first < 1 then first = 1 end
        local last = math.floor((self.height - scroll - 1) / itemH) + 1
        if last > total then last = total end

        local altBg = self.altBgColor
        for i = first, last do
            local entry = items[i]
            entry.height = itemH
            entry.index = i
            local rowY = (i - 1) * itemH
            local alt = (i % 2 == 0)
            if alt and altBg then
                self:drawRect(0, rowY, self:getWidth(), itemH - 1,
                    altBg.r, altBg.g, altBg.b, altBg.a)
            end
            self:doDrawItem(rowY, entry, alt)
        end

        self.listHeight = total * itemH
        self:setScrollHeight(self.listHeight)
        self:clearStencilRect()
        if self.doRepaintStencil then
            self:repaintStencilRect(stencilX, stencilY,
                stencilX2 - stencilX, stencilY2 - stencilY)
        end

        local mouseY = self:getMouseY()
        self:updateSmoothScrolling()
        if mouseY ~= self:getMouseY() and self:isMouseOver() then
            self:onMouseMove(0, self:getMouseY() - mouseY)
        end
        self:updateTooltip()
    end

    RWMArgenRadioStations = RWMPanel:derive("RWMArgenRadioStations")

    function RWMArgenRadioStations:createList(x, y, width)
        local list = ArgenRadioList:new(x, y, width, LIB_LIST_H)
        list:initialise()
        list:instantiate()
        list:setFont(UIFont.Small, 3)
        list.itemheight = FONT_HGT_SMALL + 8
        list.drawBorder = true
        list.backgroundColor = { r = LCD_BG.r, g = LCD_BG.g, b = LCD_BG.b, a = 0.55 }
        list.borderColor = { r = 0.32, g = 0.36, b = 0.42, a = 0.9 }
        list.textColor = { r = 0.85, g = 0.87, b = 0.90, a = 1.0 }
        list.selectedTextColor = { r = 1.0, g = 1.0, b = 1.0, a = 1.0 }
        list.selectionColor = { r = ACCENT.r, g = ACCENT.g, b = ACCENT.b, a = 0.30 }
        list.mouseOverHighlightColor = { r = 1.0, g = 1.0, b = 1.0, a = 0.10 }
        self:addChild(list)
        return list
    end

    function RWMArgenRadioStations:createChildren()
        local pad = UI_BORDER_SPACING
        local avail = self.width - pad * 2 - 2
        local twoGaps = LIB_GAP * 2
        local colGenre = math.floor((avail - twoGaps) * 0.26)
        local colArtist = math.floor((avail - twoGaps) * 0.30)
        local colSong = avail - twoGaps - colGenre - colArtist

        self.labelY = pad
        self.labelH = FONT_HGT_SMALL + 4
        local listY = pad + self.labelH
        local x1 = pad + 1
        local x2 = x1 + colGenre + LIB_GAP
        local x3 = x2 + colArtist + LIB_GAP

        self.genresX = x1
        self.artistsX = x2
        self.songsX = x3
        self.songColW = colSong

        self.genreList = self:createList(x1, listY, colGenre)
        self.artistList = self:createList(x2, listY, colArtist)
        self.songList = self:createList(x3, listY, colSong)

        self.genreList:setOnMouseDownFunction(self, RWMArgenRadioStations.onGenreClick)
        self.artistList:setOnMouseDownFunction(self, RWMArgenRadioStations.onArtistClick)
        self.songList:setOnMouseDownFunction(self, RWMArgenRadioStations.onSongClick)

        local stations = ArgenRadio.getStations()
        for i = 1, #stations do
            self.genreList:addItem(stationTitle(stations[i]), i)
        end

        local btnY = listY + LIB_LIST_H + 8
        self.genreModeButton = ISButton:new(x1, btnY, colGenre, BUTTON_HGT,
            "Genero: Aleatorio", self, RWMArgenRadioStations.onGenreMode)
        self.genreModeButton:initialise()
        self.genreModeButton:setFont(UIFont.Small)
        self:addChild(self.genreModeButton)

        self.artistModeButton = ISButton:new(x2, btnY, colArtist, BUTTON_HGT,
            "Artista: Aleatorio", self, RWMArgenRadioStations.onArtistMode)
        self.artistModeButton:initialise()
        self.artistModeButton:setFont(UIFont.Small)
        self:addChild(self.artistModeButton)

        -- Reproduce la seleccion local. No es el encendido/apagado del
        -- modulo principal: solo manda el cambio cuando se aprieta.
        self.playSelButton = ISButton:new(x3, btnY, colSong, BUTTON_HGT,
            "Reproducir", self, RWMArgenRadioStations.onPlaySelection)
        self.playSelButton:initialise()
        self.playSelButton:setFont(UIFont.Small)
        self:addChild(self.playSelButton)

        self:setHeight(btnY + BUTTON_HGT + pad)
    end

    function RWMArgenRadioStations:readFromObject(_player, _deviceObject, _deviceData, _deviceType)
        RWMPanel.readFromObject(self, _player, _deviceObject, _deviceData, _deviceType)

        if not _deviceData then return false end
        if _deviceData:getIsTelevision() or _deviceData:getIsTwoWay() then
            return false
        end
        -- Si el motor de audio no termino de cargar, no romper la ventana.
        if not (ArgenRadio.Audio and ArgenRadio.Audio.getState) then
            return false
        end

        self.state = ArgenRadio.Audio.getState(_deviceObject, _deviceType)
        -- Al abrir, la seleccion arranca en lo que esta sonando.
        self:resetSelection()
        self:refreshAll()
        return true
    end

    -- La seleccion es solo de esta ventana. No viaja al servidor ni toca el
    -- audio hasta que se aprieta "Reproducir".
    function RWMArgenRadioStations:resetSelection()
        local state = self.state
        if not state then return end
        self.selStation = state.station or 1
        self.selArtist = state.artist or ""
        self.selTrack = state.track or nil
        -- Mientras sigue la reproduccion, la seleccion acompaña al motor.
        self.selFollow = true
        self.pendingPlay = nil
    end

    function RWMArgenRadioStations:clear()
        RWMPanel.clear(self)
        self.state = nil
        self.selStation = 1
        self.selArtist = ""
        self.selTrack = nil
        self.selFollow = true
        self.pendingPlay = nil
        self.lastGenreMode = nil
        self.lastArtistMode = nil
    end

    function RWMArgenRadioStations:artistRow(artistId)
        artistId = tostring(artistId or "")
        for i, entry in ipairs(self.artistList.items) do
            if (entry.item or "") == artistId then return i end
        end
        return 1
    end

    function RWMArgenRadioStations:songRow(trackIndex)
        if not trackIndex then return 0 end
        for i, entry in ipairs(self.songList.items) do
            if entry.item == trackIndex then return i end
        end
        return 0
    end

    function RWMArgenRadioStations:refreshGenres()
        if not self.state then return end
        self.genreList.selected = self.selStation or 1
    end

    function RWMArgenRadioStations:refreshArtists()
        if not self.state then return end

        local list = self.artistList
        list:clear()
        list:addItem("Todo el genero", "")
        local artists = ArgenRadio.getStationArtists(self.selStation)
        for i = 1, #artists do
            list:addItem(artists[i].nombre or artists[i].id, artists[i].id)
        end
        list:setYScroll(0)
        local row = self:artistRow(self.selArtist)
        if row > 0 then list:ensureVisible(row) end
    end

    function RWMArgenRadioStations:refreshSongs()
        if not self.state then return end

        local list = self.songList
        list:clear()
        local tracks = ArgenRadio.getScopeTracks(self.selStation, self.selArtist)
        local showArtist = (self.selArtist or "") == ""
        for i = 1, #tracks do
            local track = tracks[i]
            local text
            if showArtist then
                text = (track.artista or "?") .. " - " .. (track.titulo or "--")
            else
                text = track.titulo or "--"
            end
            list:addItem(text, track.index, (track.artista or "") .. "\n" .. (track.titulo or ""))
        end
        list:setYScroll(0)
        local row = self:songRow(self.selTrack)
        if row > 0 then list:ensureVisible(row) end
    end

    function RWMArgenRadioStations:refreshButtons()
        local state = self.state
        if not state then return end
        local genreListMode = state.genreMode == ArgenRadio.MODE_LIST and "En fila" or "Aleatorio"
        local artistListMode = state.artistMode == ArgenRadio.MODE_LIST and "En fila" or "Aleatorio"
        self.genreModeButton:setTitle("Genero: " .. genreListMode)
        self.artistModeButton:setTitle("Artista: " .. artistListMode)
    end

    function RWMArgenRadioStations:refreshSelection()
        if not self.state then return end
        self.genreList.selected = self.selStation or 1
        self.artistList.selected = self:artistRow(self.selArtist)
        self.songList.selected = self:songRow(self.selTrack)
    end

    -- Marca en cada lista la fila que esta sonando. Solo se muestra cuando
    -- la emisora/artista que suena coincide con lo que hay en pantalla.
    function RWMArgenRadioStations:refreshPlaying()
        local state = self.state
        if not state then return end

        local playing = state.playing and true or false
        local station = state.station or 1
        local artist = state.artist or ""

        self.genreList.playingItem = playing and station or nil
        self.artistList.playingItem =
            (playing and station == self.selStation) and artist or nil
        if playing and station == self.selStation and artist == self.selArtist then
            self.songList.playingItem = state.track
        else
            self.songList.playingItem = nil
        end
    end

    -- "Reproducir" esta activo solo si la seleccion no es ya lo que suena.
    function RWMArgenRadioStations:refreshPlayButton()
        local button = self.playSelButton
        local state = self.state
        if not button or not state then return end

        local tracks = ArgenRadio.getScopeTracks(self.selStation, self.selArtist)
        local hasTracks = #tracks > 0
        local same = state.playing
            and (state.station or 1) == self.selStation
            and (state.artist or "") == self.selArtist
            and (self.selTrack == nil or self.selTrack == state.track)

        local title, enabled
        if not hasTracks then
            title, enabled = "Sin temas", false
        elseif same then
            title, enabled = "Sonando", false
        else
            title, enabled = "Reproducir", true
        end

        if self.playSelTitle ~= title or self.playSelEnabled ~= enabled then
            self.playSelTitle = title
            self.playSelEnabled = enabled
            button:setTitle(title)
            button:setEnable(enabled)
        end
    end

    function RWMArgenRadioStations:refreshAll()
        if not self.state then return end
        self:refreshGenres()
        self:refreshArtists()
        self:refreshSongs()
        self:refreshSelection()
        self:refreshButtons()
        self:refreshPlaying()
        self:refreshPlayButton()

        self.lastGenreMode = self.state.genreMode
        self.lastArtistMode = self.state.artistMode
    end

    function RWMArgenRadioStations:update()
        ISPanel.update(self)
        if not self.device or not self.state then return end

        local state = self.state
        local now = getTimestampMs and getTimestampMs() or 0
        ArgenRadio._panelActiveMs = now

        -- Refrescar botones y filas "sonando" no necesita ocurrir en cada
        -- fotograma. Los clics llaman a refresh* directamente, asi que la
        -- unica demora posible es la de un cambio que llega por red.
        if now < (self.nextRefreshMs or 0) then return end
        self.nextRefreshMs = now + 150

        -- Cuando se aprieta "Reproducir", esperamos el estado nuevo (en MP
        -- llega por red) para volver a seguir la reproduccion. Si el comando
        -- no prospera, la seleccion se queda como estaba.
        local pending = self.pendingPlay
        if pending then
            local matched = state.playing
                and (state.station or 1) == pending.station
                and (state.artist or "") == pending.artist
                and (pending.track == nil or state.track == pending.track)
            if matched then
                self.pendingPlay = nil
                self.selFollow = true
                self.selTrack = state.track
            elseif now > pending.untilMs then
                self.pendingPlay = nil
            end
        end

        -- Sin clics en las listas, la seleccion acompaña lo que suena.
        if self.selFollow then
            local station = state.station or 1
            local artist = state.artist or ""
            local rebuild = (station ~= self.selStation) or (artist ~= self.selArtist)
            self.selStation = station
            self.selArtist = artist
            self.selTrack = state.track or nil
            if rebuild then
                self:refreshArtists()
                self:refreshSongs()
            end
            self:refreshSelection()
        end

        if state.genreMode ~= self.lastGenreMode or state.artistMode ~= self.lastArtistMode then
            self:refreshButtons()
            self.lastGenreMode = state.genreMode
            self.lastArtistMode = state.artistMode
        end

        self:refreshPlaying()
        self:refreshPlayButton()
    end

    function RWMArgenRadioStations:render()
        ISPanel.render(self)
        local dim = TEXT_DIM
        self:drawText("Generos", self.genresX, self.labelY,
            dim.r, dim.g, dim.b, 1.0, UIFont.Small)
        self:drawText("Artistas", self.artistsX, self.labelY,
            dim.r, dim.g, dim.b, 1.0, UIFont.Small)
        self:drawText("Canciones (" .. tostring(#self.songList.items) .. ")",
            self.songsX, self.labelY, dim.r, dim.g, dim.b, 1.0, UIFont.Small)

        -- Indicador de lo que esta sonando, dibujado (no depende del font).
        if self.songList and self.songList.playingItem ~= nil then
            local label = "Sonando"
            local textX = self.songsX + self.songColW - SONANDO_WIDTH
            local triY = self.labelY + math.floor((FONT_HGT_SMALL - 6) / 2)
            drawPlayTriangle(self, textX - 10, triY,
                ACCENT.r, ACCENT.g, ACCENT.b, 1.0)
            self:drawText(label, textX, self.labelY,
                ACCENT.r, ACCENT.g, ACCENT.b, 1.0, UIFont.Small)
        end
    end

    -- ISButton / ISScrollingListBox pasan (panel, ...), por eso no usamos
    -- sintaxis de metodo (dos puntos) en los handlers.
    --
    -- Los clics de las listas SOLO mueven la seleccion local: no llaman al
    -- motor de audio ni mandan comandos al servidor.
    function RWMArgenRadioStations.onGenreClick(panel, stationIndex)
        if not panel.state or not stationIndex then return end
        panel.selFollow = false
        panel.pendingPlay = nil
        panel.selStation = stationIndex
        panel.selArtist = ""
        panel.selTrack = nil
        panel:refreshArtists()
        panel:refreshSongs()
        panel:refreshSelection()
        panel:refreshPlaying()
        panel:refreshPlayButton()
    end

    function RWMArgenRadioStations.onArtistClick(panel, artistId)
        if not panel.state then return end
        panel.selFollow = false
        panel.pendingPlay = nil
        artistId = tostring(artistId or "")
        if not ArgenRadio.isValidArtist(panel.selStation, artistId) then
            artistId = ""
        end
        panel.selArtist = artistId
        panel.selTrack = nil
        panel:refreshSongs()
        panel:refreshSelection()
        panel:refreshPlaying()
        panel:refreshPlayButton()
    end

    function RWMArgenRadioStations.onSongClick(panel, trackIndex)
        if not panel.state or not trackIndex then return end
        panel.selFollow = false
        panel.pendingPlay = nil
        panel.selTrack = trackIndex
        panel:refreshSelection()
        panel:refreshPlayButton()
    end

    -- Unico punto que manda la seleccion al motor/servidor. Si no hay tema
    -- puntual elegido (genero u artista), el motor elige uno segun el modo.
    function RWMArgenRadioStations.onPlaySelection(panel)
        if not panel.state or not panel.device then return end
        local tracks = ArgenRadio.getScopeTracks(panel.selStation, panel.selArtist)
        if #tracks == 0 then return end

        local ok, err = ArgenRadio.Audio.playSelection(
            panel.player, panel.device, panel.deviceType,
            panel.selStation, panel.selArtist, panel.selTrack)
        if not ok and err then
            print("[ArgenRadio] " .. tostring(err))
            if panel.player and HaloTextHelper then
                HaloTextHelper.addBadText(panel.player, err)
            end
            return
        end

        panel.selFollow = false
        panel.pendingPlay = {
            station = panel.selStation,
            artist = panel.selArtist,
            track = panel.selTrack,
            untilMs = (getTimestampMs and getTimestampMs() or 0) + 3000,
        }
        panel:refreshPlayButton()
    end

    function RWMArgenRadioStations.onGenreMode(panel)
        if not panel.state then return end
        local mode = panel.state.genreMode == ArgenRadio.MODE_LIST
            and ArgenRadio.MODE_RANDOM or ArgenRadio.MODE_LIST
        ArgenRadio.Audio.setMode(
            panel.player, panel.device, panel.deviceType, "genre", mode)
    end

    function RWMArgenRadioStations.onArtistMode(panel)
        if not panel.state then return end
        local mode = panel.state.artistMode == ArgenRadio.MODE_LIST
            and ArgenRadio.MODE_RANDOM or ArgenRadio.MODE_LIST
        ArgenRadio.Audio.setMode(
            panel.player, panel.device, panel.deviceType, "artist", mode)
    end

    function RWMArgenRadioStations:new(x, y, width, height)
        local o = RWMPanel:new(x, y, width, height)
        setmetatable(o, self)
        self.__index = self
        o.x = x
        o.y = y
        o.width = width
        o.height = height
        o.state = nil
        o.genreList = nil
        o.artistList = nil
        o.songList = nil
        o.genreModeButton = nil
        o.artistModeButton = nil
        o.playSelButton = nil
        o.selStation = 1
        o.selArtist = ""
        o.selTrack = nil
        o.selFollow = true
        o.pendingPlay = nil
        o.playSelTitle = nil
        o.playSelEnabled = nil
        o.lastGenreMode = nil
        o.lastArtistMode = nil
        o.labelY = 0
        o.labelH = 0
        o.genresX = 0
        o.artistsX = 0
        o.songsX = 0
        o.songColW = 0
        return o
    end

    ---------------------------------------------------------------
    -- Enganche en ISRadioWindow (envolver, no pisar)
    ---------------------------------------------------------------

    -- Ventana mas ancha para que entren las tres columnas y el dial.
    local baseNew = ISRadioWindow.new
    function ISRadioWindow:new(x, y, width, height, player)
        if width < WINDOW_MIN_WIDTH then width = WINDOW_MIN_WIDTH end
        return baseNew(self, x, y, width, height, player)
    end

    local baseCreateChildren = ISRadioWindow.createChildren
    function ISRadioWindow:createChildren()
        -- Por si el layout guardado restaura un ancho viejo.
        if self.width < WINDOW_MIN_WIDTH then
            self:setWidth(WINDOW_MIN_WIDTH)
        end

        baseCreateChildren(self)

        self:addModule(RWMArgenRadio:new(0, 0, self.width, 0), "ArgenRadio", false)
        self.argenRadioModule = self.modules[#self.modules]

        self:addModule(RWMArgenRadioStations:new(0, 0, self.width, 0), "Generos", false)
        self.argenRadioStationsModule = self.modules[#self.modules]
    end

    local baseReadFromObject = ISRadioWindow.readFromObject
    function ISRadioWindow:readFromObject(_player, _deviceObject)
        baseReadFromObject(self, _player, _deviceObject)

        if not self.argenRadioModule then return end

        local deviceData = self.deviceData
        local isArgenRadio = deviceData
            and not deviceData:getIsTelevision()
            and not deviceData:getIsTwoWay()

        if not isArgenRadio then
            -- TV y walkie-talkie: queda todo como vanilla.
            return
        end

        -- Radio comun: solo los paneles ArgenRadio.
        for i = 1, #self.modules do
            local module = self.modules[i]
            local enabled = (module == self.argenRadioModule)
                or (module == self.argenRadioStationsModule)
            module.enabled = enabled
            module.element:setVisible(enabled)
        end

        self.hotKeyPanels = {}
        self.title = "ArgenRadio - " .. tostring(deviceData:getDeviceName())
    end

    print("[ArgenRadio] Panel instalado en la ventana de radio")
end

Events.OnGameBoot.Add(installArgenRadioWindow)

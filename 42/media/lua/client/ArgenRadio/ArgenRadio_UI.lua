-- ArgenRadio - ventana de radio (etapa 4)
-- Rediseño estilo vanilla: un modulo principal con pantalla de sintonia
-- (estetica, sin funcion real) y un segundo modulo plegable "Generos".
-- Se aplica a radios de vehiculo, de casa y portatiles.
-- No toca televisores ni walkie-talkies (two-way).

local UI_BORDER_SPACING = 10
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_LARGE = getTextManager():getFontHeight(UIFont.Large)
local BUTTON_HGT = FONT_HGT_SMALL + 8
local WINDOW_MIN_WIDTH = 430

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
        local station, index = ArgenRadio.getStation(panel.stationIndex or 1)
        station = station or {}
        index = index or 1

        local freq = tostring(station.freq or "--.-")
        local name = tostring(station.nombre or "ArgenRadio")

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

        local mhz = "MHz"
        local mhzW = getTextManager():MeasureStringX(UIFont.Small, mhz)
        panel:drawText(mhz, right - mhzW, fmY,
            TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1.0, UIFont.Small)
        panel:drawTextRight(freq, right - mhzW - 6, topY,
            ACCENT_SOFT.r, ACCENT_SOFT.g, ACCENT_SOFT.b, 1.0, UIFont.Large)

        -- Centro: nombre de la emisora.
        local nameY = topY + FONT_HGT_LARGE + 6
        panel:drawTextCentre(name, x + w / 2, nameY,
            TEXT_MAIN.r, TEXT_MAIN.g, TEXT_MAIN.b, 1.0, UIFont.Large)

        -- Abajo: tema actual a la izquierda y numero de tema a la derecha.
        local ruleY = y + h - 10
        local trackY = ruleY - FONT_HGT_SMALL - 8
        local tracks = ArgenRadio.getStationTracks(index)
        local trackIndex = state and state.track or 1
        local track = tracks[trackIndex]
        local trackTitle = track and track.titulo or "--"

        local noteY = trackY + FONT_HGT_SMALL - 6
        drawNote(panel, left, noteY, ACCENT.r, ACCENT.g, ACCENT.b, 0.95)
        panel:drawText(trackTitle, left + 12, trackY,
            TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1.0, UIFont.Small)
        panel:drawTextRight(tostring(trackIndex) .. " / " .. tostring(#tracks),
            right, trackY, TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1.0, UIFont.Small)

        -- Linea fina inferior (escala) y marca celeste de la emisora.
        panel:drawRect(left, ruleY, right - left, 1, 1.0,
            RULE.r, RULE.g, RULE.b)

        local count = #ArgenRadio.STATIONS
        local minFreq, maxFreq
        for i = 1, count do
            local f = tonumber(ArgenRadio.STATIONS[i].freq)
            if f then
                if not minFreq or f < minFreq then minFreq = f end
                if not maxFreq or f > maxFreq then maxFreq = f end
            end
        end

        -- La marca se ubica segun la frecuencia, como un dial real.
        local scaleL, scaleR = left + 4, right - 4
        local t = 0.5
        local freqNum = tonumber(station.freq)
        if minFreq and maxFreq and maxFreq > minFreq and freqNum then
            t = (freqNum - minFreq) / (maxFreq - minFreq)
        elseif count > 1 then
            t = (index - 1) / (count - 1)
        end
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
        self.dialH = math.max(124, FONT_HGT_LARGE * 2 + FONT_HGT_SMALL + 56)

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
        self.volumeBar:setVolume(math.floor(self.state.volume * self.volumeBar:getVolumeSteps()))
        self.volumeBar:setEnableControls(not self.state.muted)
        self.speakerButton.isMute = self.state.muted and true or false
        self.speakerButton:setEnableControls(true)
        self:refreshControls()
        return true
    end

    function RWMArgenRadio:clear()
        RWMPanel.clear(self)
        self.state = nil
        self.stationIndex = 1
        self.lastPlaying = nil
    end

    function RWMArgenRadio:refreshControls()
        if not self.state then return end
        if self.playButton then
            self.playButton:setTitle(self.state.playing and "Detener" or "Reproducir")
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
            -- motor elija uno al azar para que no arranque siempre igual.
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

        local playing = ArgenRadio.Audio.isPlaying(self.device, self.deviceType)
        local station = self.state.station or 1
        if self.state.playing ~= playing then
            self.state.playing = playing
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
        o.dialX = 0
        o.dialY = 0
        o.dialW = 0
        o.dialH = 0
        o.controlsY = 0
        return o
    end

    ---------------------------------------------------------------
    -- Modulo plegable: lista de generos / emisoras
    ---------------------------------------------------------------
    RWMArgenRadioStations = RWMPanel:derive("RWMArgenRadioStations")

    function RWMArgenRadioStations:createChildren()
        local pad = UI_BORDER_SPACING
        local rowGap = 3
        local rowH = BUTTON_HGT + 2
        local rowW = self.width - pad * 2 - 2

        self.rows = {}
        for i = 1, #ArgenRadio.STATIONS do
            local station = ArgenRadio.STATIONS[i]
            local y = pad + (i - 1) * (rowH + rowGap)
            local row = ISButton:new(pad + 1, y, rowW, rowH,
                stationTitle(station), self, RWMArgenRadioStations.onSelect)
            row:initialise()
            row:setFont(UIFont.Small)
            row.titleLeft = true
            row.onClickArgs = { i }
            row.backgroundColor = { r = 1.0, g = 1.0, b = 1.0, a = 0.02 }
            row.backgroundColorMouseOver = { r = 1.0, g = 1.0, b = 1.0, a = 0.16 }
            row.borderColor = { r = 1.0, g = 1.0, b = 1.0, a = 0.12 }
            row.textColor = { r = 0.85, g = 0.85, b = 0.85, a = 1.0 }
            self:addChild(row)
            self.rows[i] = row
        end

        self:setHeight(pad * 2 + #ArgenRadio.STATIONS * (rowH + rowGap) - rowGap)
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
        self.lastSelected = nil
        self:refresh()
        return true
    end

    function RWMArgenRadioStations:clear()
        RWMPanel.clear(self)
        self.state = nil
        self.lastSelected = nil
    end

    function RWMArgenRadioStations:refresh()
        local selected = self.state and self.state.station or 1
        self.lastSelected = selected
        for i, row in ipairs(self.rows or {}) do
            local on = (i == selected)
            row.backgroundColor.r = on and ACCENT.r or 1.0
            row.backgroundColor.g = on and ACCENT.g or 1.0
            row.backgroundColor.b = on and ACCENT.b or 1.0
            row.backgroundColor.a = on and 0.16 or 0.02
            row.borderColor.r = on and ACCENT.r or 1.0
            row.borderColor.g = on and ACCENT.g or 1.0
            row.borderColor.b = on and ACCENT.b or 1.0
            row.borderColor.a = on and 0.80 or 0.12
            row.textColor.r = on and 1.0 or 0.75
            row.textColor.g = on and 1.0 or 0.75
            row.textColor.b = on and 1.0 or 0.75
        end
    end

    function RWMArgenRadioStations:update()
        ISPanel.update(self)
        if not self.device or not self.state then return end
        local selected = self.state.station or 1
        if selected ~= self.lastSelected then
            self:refresh()
        end
    end

    -- ISButton llama onclick(target, boton, args...), asi que el primer
    -- parametro es el panel y no usamos sintaxis de metodo (dos puntos).
    function RWMArgenRadioStations.onSelect(panel, _button, index)
        if not panel.state then return end
        local ok, err = ArgenRadio.Audio.setStation(
            panel.player, panel.device, panel.deviceType, index)
        if not ok and err then
            print("[ArgenRadio] " .. tostring(err))
        end
        panel:refresh()
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
        o.lastSelected = nil
        o.rows = nil
        return o
    end

    ---------------------------------------------------------------
    -- Enganche en ISRadioWindow (envolver, no pisar)
    ---------------------------------------------------------------

    -- Ventana un poco mas ancha para que la pantalla de sintonia respire.
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

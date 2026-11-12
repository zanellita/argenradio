-- ArgenRadio - ventana de radio (etapas 4.1, 5 y biblioteca 0.6)
-- Rediseño estilo vanilla: un modulo principal con pantalla de sintonia
-- (estetica, sin funcion real) y un segundo modulo plegable "Generos".
-- Se aplica a radios de vehiculo, de casa y portatiles.
-- No toca televisores ni walkie-talkies (two-way).
--
-- El modulo "Generos" es genero -> artista -> canciones:
--   * clic en un genero cambia de emisora;
--   * "Todo el genero" reproduce el genero completo;
--   * clic en un artista limita la reproduccion a ese artista;
--   * clic en una cancion reproduce ese tema puntual;
--   * cada ambito (genero / artista) tiene su modo aleatorio o en fila.

require "ISUI/ISScrollingListBox"

local UI_BORDER_SPACING = 10
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_LARGE = getTextManager():getFontHeight(UIFont.Large)
local BUTTON_HGT = FONT_HGT_SMALL + 8
local WINDOW_MIN_WIDTH = 560
local LIB_LIST_H = 132
local LIB_GAP = 6

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

        -- Centro: nombre de la emisora y ambito actual (artista o genero).
        local nameY = topY + FONT_HGT_LARGE + 6
        panel:drawTextCentre(name, x + w / 2, nameY,
            TEXT_MAIN.r, TEXT_MAIN.g, TEXT_MAIN.b, 1.0, UIFont.Large)

        local artistId = state and state.artist or ""
        local scopeName = ArgenRadio.getScopeName(index, artistId)
        local scopeColor = (artistId ~= "") and ACCENT_SOFT or TEXT_DIM
        panel:drawTextCentre(scopeName, x + w / 2, nameY + FONT_HGT_LARGE + 1,
            scopeColor.r, scopeColor.g, scopeColor.b, 1.0, UIFont.Small)

        -- Abajo: tema actual a la izquierda y posicion + modo a la derecha.
        local ruleY = y + h - 10
        local trackY = ruleY - FONT_HGT_SMALL - 8
        local scopeTracks = ArgenRadio.getScopeTracks(index, artistId)
        local trackIndex = state and state.track or 1
        local total = #scopeTracks
        local position = 0
        for i = 1, total do
            if scopeTracks[i].index == trackIndex then
                position = i
                break
            end
        end

        local mode = ArgenRadio.getActiveMode(state)
        local modeLabel = (mode == ArgenRadio.MODE_LIST) and "En fila" or "Aleatorio"
        local rightText = tostring(position) .. "/" .. tostring(total)
            .. "  " .. modeLabel
        local rightW = getTextManager():MeasureStringX(UIFont.Small, rightText)

        local trackTitle = fitText(
            ArgenRadio.getTrackTitle(index, trackIndex),
            (right - left) - 12 - rightW - 10)

        local noteY = trackY + FONT_HGT_SMALL - 6
        drawNote(panel, left, noteY, ACCENT.r, ACCENT.g, ACCENT.b, 0.95)
        panel:drawText(trackTitle, left + 12, trackY,
            TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1.0, UIFont.Small)
        panel:drawTextRight(rightText, right, trackY,
            TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1.0, UIFont.Small)

        -- Linea fina inferior (escala) y marca celeste de la emisora.
        panel:drawRect(left, ruleY, right - left, 1, 1.0,
            RULE.r, RULE.g, RULE.b)

        local count = #ArgenRadio.getStations()
        local minFreq, maxFreq
        for i = 1, count do
            local f = tonumber(ArgenRadio.getStations()[i].freq)
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

        local playing = ArgenRadio.Audio.isPlaying(self.device, self.deviceType)
        local station = self.state.station or 1
        if self.state.playing ~= playing then
            self.state.playing = playing
        end

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
    RWMArgenRadioStations = RWMPanel:derive("RWMArgenRadioStations")

    function RWMArgenRadioStations:createList(x, y, width)
        local list = ISScrollingListBox:new(x, y, width, LIB_LIST_H)
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
        self:refreshAll()
        return true
    end

    function RWMArgenRadioStations:clear()
        RWMPanel.clear(self)
        self.state = nil
        self.lastStation = nil
        self.lastArtist = nil
        self.lastTrack = nil
        self.lastGenreMode = nil
        self.lastArtistMode = nil
    end

    function RWMArgenRadioStations:refreshGenres()
        local state = self.state
        if not state then return end
        self.genreList.selected = state.station or 1
    end

    function RWMArgenRadioStations:refreshArtists()
        local state = self.state
        if not state then return end

        local list = self.artistList
        list:clear()
        list:addItem("Todo el genero", "")
        local artists = ArgenRadio.getStationArtists(state.station)
        for i = 1, #artists do
            list:addItem(artists[i].nombre or artists[i].id, artists[i].id)
        end
        list:setYScroll(0)
    end

    function RWMArgenRadioStations:refreshSongs()
        local state = self.state
        if not state then return end

        local list = self.songList
        list:clear()
        local tracks = ArgenRadio.getScopeTracks(state.station, state.artist)
        local showArtist = (state.artist or "") == ""
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
        local state = self.state
        if not state then return end

        self.genreList.selected = state.station or 1

        local artistRow = 1
        local artistId = state.artist or ""
        for i, entry in ipairs(self.artistList.items) do
            if (entry.item or "") == artistId then
                artistRow = i
                break
            end
        end
        self.artistList.selected = artistRow

        local songRow = 0
        for i, entry in ipairs(self.songList.items) do
            if entry.item == state.track then
                songRow = i
                break
            end
        end
        self.songList.selected = songRow
    end

    function RWMArgenRadioStations:refreshAll()
        if not self.state then return end
        self:refreshGenres()
        self:refreshArtists()
        self:refreshSongs()
        self:refreshButtons()
        self:refreshSelection()

        self.lastStation = self.state.station or 1
        self.lastArtist = self.state.artist or ""
        self.lastTrack = self.state.track or 1
        self.lastGenreMode = self.state.genreMode
        self.lastArtistMode = self.state.artistMode
    end

    function RWMArgenRadioStations:update()
        ISPanel.update(self)
        if not self.device or not self.state then return end

        local state = self.state
        local station = state.station or 1
        local artist = state.artist or ""

        if station ~= self.lastStation or artist ~= self.lastArtist then
            self:refreshAll()
            return
        end

        if state.track ~= self.lastTrack then
            self:refreshSelection()
            self.lastTrack = state.track
        end

        if state.genreMode ~= self.lastGenreMode or state.artistMode ~= self.lastArtistMode then
            self:refreshButtons()
            self.lastGenreMode = state.genreMode
            self.lastArtistMode = state.artistMode
        end
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
    end

    -- ISButton / ISScrollingListBox pasan (panel, ...), por eso no usamos
    -- sintaxis de metodo (dos puntos) en los handlers.
    function RWMArgenRadioStations.onGenreClick(panel, stationIndex)
        if not panel.state then return end
        local ok, err = ArgenRadio.Audio.setStation(
            panel.player, panel.device, panel.deviceType, stationIndex)
        if not ok and err then
            print("[ArgenRadio] " .. tostring(err))
        end
    end

    function RWMArgenRadioStations.onArtistClick(panel, artistId)
        if not panel.state then return end
        local ok, err = ArgenRadio.Audio.setScope(
            panel.player, panel.device, panel.deviceType, artistId or "")
        if not ok and err then
            print("[ArgenRadio] " .. tostring(err))
        end
    end

    function RWMArgenRadioStations.onSongClick(panel, trackIndex)
        if not panel.state then return end
        local ok, err = ArgenRadio.Audio.selectTrack(
            panel.player, panel.device, panel.deviceType, trackIndex)
        if not ok and err then
            print("[ArgenRadio] " .. tostring(err))
        end
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
        o.lastStation = nil
        o.lastArtist = nil
        o.lastTrack = nil
        o.lastGenreMode = nil
        o.lastArtistMode = nil
        o.labelY = 0
        o.labelH = 0
        o.genresX = 0
        o.artistsX = 0
        o.songsX = 0
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

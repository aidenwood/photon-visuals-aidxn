extension WorkspaceModel {
    @discardableResult public func reloadMasterPreview() -> Task<Void, Never> {
        let provider = provider
        return masterPreview.load { try await provider.masterPreview().validated() }
    }

    @discardableResult public func reloadLayers() -> Task<Void, Never> {
        let provider = provider, deckID = selectedDeckID
        return layers.load { try await provider.layers(deckID: deckID).validated() }
    }

    @discardableResult public func reloadMaster() -> Task<Void, Never> {
        let provider = provider
        return master.load { try await provider.master().validated() }
    }

    public func triggerClip(_ clipID: String, layerID: String, slotID: String? = nil) {
        guard !isSwitchingDeck else { return }
        selectClip(clipID)
        selectedLayerID = layerID
        selectedSlotID = slotID
        liveCommand(.triggerClip(clipID: clipID, layerID: layerID))
    }

    public func triggerColumn(_ index: Int) {
        guard !isSwitchingDeck else { return }
        if let clip = layers.value?.layers.first?.slot(in: index)?.clip {
            selectClip(clip.id)
        }
        selectedColumn = index
        selectedSlotID = nil
        inspectorScope = .column
        liveCommand(.triggerColumn(column: index, deckID: layers.value?.deckID))
    }

    public func selectDeck(_ id: String) {
        guard layers.value?.decks.contains(where: { $0.id == id }) == true else { return }
        guard selectedDeckID != id, !(selectedDeckID == nil && layers.value?.deckID == id) else { return }
        selectedDeckID = id
        selectedColumn = nil
        selectedSlotID = nil
        reloadLayers()
    }

    private var isSwitchingDeck: Bool {
        layers.phase.isLoading && selectedDeckID != nil && layers.value?.deckID != selectedDeckID
    }

    public func setLayerOpacity(_ value: Double, layerID: String) {
        commands.send(.setLayerOpacity(layerID: layerID, value: value)) { [weak self] in
            self?.controlRefresh.schedule(.layers) { [weak self] in self?.reloadLayers() }
        } failed: { [weak self] issue in self?.layers.report(issue) }
    }

    public func toggleLayerBypass(_ layer: LayerSnapshot) {
        liveCommand(.setLayerBypass(layerID: layer.id, value: !layer.bypass))
    }

    public func toggleLayerSolo(_ layer: LayerSnapshot) {
        liveCommand(.setLayerSolo(layerID: layer.id, value: !layer.solo))
    }

    public func setMasterOpacity(_ value: Double) { masterCommand(.setMasterOpacity(value)) }
    public func toggleBlackout() {
        let target = !isBlackedOut
        requestedBlackout = target
        blackoutRequest &+= 1
        let request = blackoutRequest
        commands.send(.setBlackout(target)) { [weak self] in
            guard let self else { return }
            self.controlRefresh.cancel(.master)
            let refresh = self.reloadMaster()
            Task { [weak self] in
                await refresh.value
                guard let self, self.blackoutRequest == request else { return }
                self.requestedBlackout = nil
            }
        } failed: { [weak self] issue in
            guard let self else { return }
            if self.blackoutRequest == request { self.requestedBlackout = nil }
            self.master.report(issue)
        }
    }

    public func switchPersona(_ value: WorkspacePersona) {
        guard !performanceLocked else { return }
        persona = value
        template = preferences.template(for: value)
    }

    public func switchTemplate(_ value: WorkspaceTemplate) {
        guard !performanceLocked, WorkspaceTemplate.available(for: persona).contains(value) else { return }
        template = value
        preferences.save(value, for: persona)
    }

    private func liveCommand(_ action: WorkspaceAction) {
        commands.send(action) { [weak self] in
            self?.reloadLayers()
            self?.reloadMasterPreview()
            self?.reloadTransport()
        } failed: { [weak self] issue in
            self?.layers.report(issue)
        }
    }

    private func masterCommand(_ action: WorkspaceAction) {
        commands.send(action) { [weak self] in
            self?.controlRefresh.schedule(.master) { [weak self] in self?.reloadMaster() }
        } failed: { [weak self] issue in
            self?.master.report(issue)
        }
    }
}

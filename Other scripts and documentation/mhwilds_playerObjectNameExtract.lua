local pm = sdk.get_managed_singleton("app.PlayerManager")
if pm then
    log.info("Got PlayerManager OK")
    local player = pm:call("getMasterPlayer")
    if player then
        log.info("Player type: " .. player:get_type_definition():get_full_name())
    else
        log.info("getMasterPlayer returned nil")
    end
else
    log.info("PlayerManager singleton not found")
end
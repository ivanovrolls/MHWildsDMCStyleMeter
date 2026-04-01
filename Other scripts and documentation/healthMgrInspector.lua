--discovers all available functions inside player’s health manager 
--by printing its method list

local done = false
re.on_frame(function()
    if done then return end
    done = true --one time execution only

    local pm = sdk.get_managed_singleton("app.PlayerManager") --store a lua reference to singleton in pm
    if not pm then log.info("No PlayerManager") return end

    local info = pm:call("getMasterPlayerInfo") --get player info object
    if not info then log.info("getMasterPlayerInfo returned nil") return end

    local character = info:call("get_Character") --get the HunterCharacter
    if not character then log.info("get_Character returned nil") return end

    local health = character:call("get_HunterHealth") --get health component
    if not health then log.info("get_HunterHealth returned nil") return end

    local healthMgr = health:call("get_HealthMgr") --drill into the health manager
    if not healthMgr then log.info("get_HealthMgr returned nil") return end

    log.info("HealthMgr type: " .. healthMgr:get_type_definition():get_full_name())

    local t = healthMgr:get_type_definition() --fetch type definition for health manager
    local methods = t:get_methods() --fetch methods then log
    if methods and #methods > 0 then
        log.info("=== HealthMgr methods ===")
        for _, method in ipairs(methods) do
            log.info("METHOD: " .. method:get_name())
        end
    else
        log.info("No methods on HealthMgr")
    end
end)
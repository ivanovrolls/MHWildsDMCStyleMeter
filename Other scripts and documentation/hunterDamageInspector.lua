--hooks into attack hits and prints out all internal damage 
--data fields from game damage system.

local function getCharacter()
    local pm = sdk.get_managed_singleton("app.PlayerManager") --get PlayerManager singleton
    if not pm then return nil end
    local info = pm:call("getMasterPlayerInfo") --get player info
    if not info then return nil end
    return info:call("get_Character") --return HunterCharacter
end

sdk.hook(
    sdk.find_type_definition("app.HunterCharacter"):get_method("evHit_AttackPostProcess"),
    nil,
    function(retval)
        local character = getCharacter()
        if not character then return retval end
        local isMaster = character:call("get_IsMaster") --filter to local player only
        if not isMaster then return retval end

        local stockDamage = character:call("get_StockDamage")
        if not stockDamage then return retval end

        local dmgInfo = stockDamage:call("get_ApplyDamageInfo")
        if not dmgInfo then return retval end

        --try get_fields on the damage info type
        local t = dmgInfo:get_type_definition()
        local fields = t:get_fields()
        if fields and #fields > 0 then
            log.info("=== cHunterDamageInfo fields ===")
            for _, f in ipairs(fields) do
                local fname = f:get_name()
                local val = f:get_data(dmgInfo) --read field value directly from object
                log.info("FIELD: " .. fname .. " = " .. tostring(val))
            end
        else
            --fallback, try common field names directly
            log.info("No fields found, trying direct access")
            local guesses = {"_damage", "_value", "_rawDamage", "_totalDamage", "_damageValue", "damage", "value"}
            for _, name in ipairs(guesses) do
                local ok, val = pcall(function() return dmgInfo:get_field(name) end)
                if ok and val then
                    log.info("FOUND: " .. name .. " = " .. tostring(val))
                end
            end
        end

        return retval
    end
)
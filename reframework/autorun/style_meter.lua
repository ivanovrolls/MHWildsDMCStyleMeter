--dmc combo meter for monster hunter wilds (reframework)
--requires reframework + reframework direct2d plugin

local ComboMeter = {}
-- ─────────────────────────────────────────────
-- Config
-- ─────────────────────────────────────────────
ComboMeter.config = {
    enabled = true,

    --rank score thresholds
    thresholds = {D=0, C=150, B=400, A=800, S=1500},

    --points per hit = _TotalDamage * hit_multiplier, capped at hit_cap
    hit_multiplier = 0.5,
    hit_cap = 200,

    --score decay per second when no hits
    decay_rate = 30,

    --seconds after last hit before combo resets
    combo_window = 6.0,

    --damage penalty = (incoming / maxHp) * penalty_scale subtracted from score
    penalty_scale = 1000,

    --rank change animation duration (seconds)
    rank_anim_duration = 0.35,

    --hud position as screen fraction (0.0 - 1.0)
    hud_x = 0.90,
    hud_y = 0.40,
}

-- ─────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────
local state = {
    score = 0,
    rank = "D",
    prev_rank = "D",
    hit_count = 0,
    last_hit_time = 0,
    rank_anim_t = 0,
    rank_changed = false,
    active = false,
    hp_before_hit = nil, --snapshot taken in evHit_Damage pre-hook
    hp_mgr_ref = nil, --health manager ref carried from pre to post hook
}

--cached singleton reference
local _pm_cache = nil

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

local function get_player_manager()
    if not _pm_cache then
        _pm_cache = sdk.get_managed_singleton("app.PlayerManager")
    end
    return _pm_cache
end

local function score_to_rank(score)
    local t = ComboMeter.config.thresholds
    if score >= t.S then return "S"
    elseif score >= t.A then return "A"
    elseif score >= t.B then return "B"
    elseif score >= t.C then return "C"
    else return "D" end
end

local function next_threshold(rank)
    local t = ComboMeter.config.thresholds
    return ({D=t.C, C=t.B, B=t.A, A=t.S, S=t.S})[rank] or t.S
end

local function cur_threshold(rank)
    local t = ComboMeter.config.thresholds
    return ({D=t.D, C=t.C, B=t.B, A=t.A, S=t.S})[rank] or 0
end

local function update_rank()
    local new_rank = score_to_rank(state.score)
    if new_rank ~= state.rank then
        state.prev_rank    = state.rank
        state.rank         = new_rank
        state.rank_changed = true
        state.rank_anim_t  = ComboMeter.config.rank_anim_duration
    end
end

-- ─────────────────────────────────────────────
-- Core logic
-- ─────────────────────────────────────────────

function ComboMeter.on_hit(total_damage)
    if not ComboMeter.config.enabled then return end

    local cfg = ComboMeter.config
    local now = os.clock()

    --reset score if combo window has elapsed
    if state.active and (now - state.last_hit_time) > cfg.combo_window then
        state.score = 0
        state.hit_count = 0
    end

    --add points scaled by damage
    --capped per hit to prevent one-shot inflation
    local pts = math.min(total_damage * cfg.hit_multiplier, cfg.hit_cap)
    state.score = state.score + pts
    state.hit_count = state.hit_count + 1
    state.last_hit_time = now
    state.active = true

    update_rank()
end

function ComboMeter.on_damage_taken(damage, max_hp)
    if not ComboMeter.config.enabled or not state.active then return end
    if damage <= 0 then return end

    --subtract penalty proportional to damage as fraction of max hp
    local penalty = (damage / max_hp) * ComboMeter.config.penalty_scale
    state.score = math.max(0, state.score - penalty)
    update_rank()
end

function ComboMeter.reset()
    state.score = 0
    state.rank = "D"
    state.prev_rank = "D"
    state.hit_count = 0
    state.last_hit_time = 0
    state.rank_anim_t = 0
    state.rank_changed = false
    state.active = false
    state.hp_before_hit = nil
    state.hp_mgr_ref = nil
    _pm_cache = nil --invalidate singleton cache on quest end
end

-- ─────────────────────────────────────────────
-- Update (decay + animation tick)
-- ─────────────────────────────────────────────
function ComboMeter.update(dt)
    if not ComboMeter.config.enabled or not state.active then return end

    local now = os.clock()

    --decay score while no hits
    if (now - state.last_hit_time) > 0.1 then
        state.score = math.max(0, state.score - ComboMeter.config.decay_rate * dt)
        update_rank()
    end

    --count down rank animation timer
    if state.rank_anim_t > 0 then
        state.rank_anim_t = math.max(0, state.rank_anim_t - dt)
        if state.rank_anim_t == 0 then
            state.rank_changed = false
        end
    end
end

-- ─────────────────────────────────────────────
-- Draw (reframework d2d - called inside d2d.on_frame, not re.on_draw)
-- ─────────────────────────────────────────────

local RANK_COLORS = {
    D = 0xFFAAAAAA,
    C = 0xFF44CCFF,
    B = 0xFF44FF88,
    A = 0xFFFFCC00,
    S = 0xFFFF3300,
}

local BAR_COLORS = {
    D = 0xFF666666,
    C = 0xFF2288CC,
    B = 0xFF22AA55,
    A = 0xFFBB9900,
    S = 0xFFCC2200,
}

local RANK_LABELS = {
    D = "DULL",
    C = "COME ON",
    B = "BADASS",
    A = "AWESOME!",
    S = "STYLISH!!",
}

function ComboMeter.draw()
    --d2d is a global provided by ref direct2d plugin
    if not ComboMeter.config.enabled then return end
    if not d2d then return end

    local sw = d2d.surface_width  or 1920
    local sh = d2d.surface_height or 1080
    local cfg = ComboMeter.config

    local base_x = sw * cfg.hud_x
    local base_y = sh * cfg.hud_y

    --elastic pop scale on rank change
    local anim_scale = 1.0
    if state.rank_anim_t > 0 then
        local t = 1 - (state.rank_anim_t / cfg.rank_anim_duration)
        anim_scale = 1.0 + 0.4 * math.exp(-t * 8) * math.cos(t * 20)
    end

    local rank = state.rank
    local rank_col = RANK_COLORS[rank] or 0xFFFFFFFF
    local bar_col = BAR_COLORS[rank] or 0xFF888888
    local label = RANK_LABELS[rank] or rank

    --rank letter with drop shadow for dmc contrast
    local font_size = math.floor(96 * anim_scale)
    local letter_x = base_x - (font_size * 0.35)
    local letter_y = base_y - (font_size * 0.5)
    d2d.text(rank, letter_x + 3, letter_y + 3, 0xAA000000, font_size)
    d2d.text(rank, letter_x, letter_y, rank_col, font_size)

    --style label below rank letter
    local label_size = 18
    local label_x = base_x - 60
    local label_y = letter_y + font_size + 4
    d2d.text(label, label_x + 1, label_y + 1, 0xAA000000, label_size)
    d2d.text(label, label_x, label_y, rank_col, label_size)

    --style bar showing progress toward next rank
    local bar_w = 120
    local bar_h = 8
    local bar_x = base_x - 60
    local bar_y = label_y + label_size + 6

    local fill_frac = 0
    local nxt = next_threshold(rank)
    local cur = cur_threshold(rank)
    if nxt > cur then
        fill_frac = math.min(1, (state.score - cur) / (nxt - cur))
    else
        fill_frac = 1 --s rank bar stays full
    end

    d2d.fill_rect(bar_x, bar_y, bar_w, bar_h, 0xFF222222)
    d2d.fill_rect(bar_x, bar_y, math.floor(bar_w * fill_frac), bar_h, bar_col)
    d2d.rect(bar_x, bar_y, bar_w, bar_h, 0xFF000000)

    --hit counter beneath bar
    local hits_text = string.format("HITS  %d", state.hit_count)
    d2d.text(hits_text, bar_x, bar_y + bar_h + 6, 0xFFCCCCCC, 14)
end

-- ─────────────────────────────────────────────
-- Reframework hooks
-- ─────────────────────────────────────────────

function ComboMeter.register_hooks()

    --resolve type definition once; abort gracefully if not found
    local hunter_type = sdk.find_type_definition("app.HunterCharacter")
    if not hunter_type then
        log.warn("[StyleMeter] app.HunterCharacter type not found, hooks skipped")
        return
    end

    -- ── damage dealt ──────────────────────────────────────
    --reentrancy guards prevent sdk method calls inside a hook from re-triggering the same hook
    local _in_attack_hook = false
    local _in_damage_hook = false

    -- ── damage dealt ──────────────────────────────────────
    local attack_method = hunter_type:get_method("evHit_AttackPostProcess")
    if attack_method then
        local captured_char = nil
        sdk.hook(
            attack_method,
            function(args)
                captured_char = nil
                if _in_attack_hook or not ComboMeter.config.enabled then return end
                local ok, this = pcall(function() return args[1] end)
                if not ok or not this then return end
                local ok2, is_master = pcall(function() return this:call("get_IsMaster") end)
                if not ok2 or not is_master then return end
                captured_char = this
            end,
            function(retval)
                if not captured_char or _in_attack_hook then return retval end
                _in_attack_hook = true
                pcall(function()
                    local stock = captured_char:call("get_StockDamage")
                    if not stock then return end
                    local dmg_info = stock:call("get_ApplyDamageInfo")
                    if not dmg_info then return end
                    if dmg_info:get_field("_IsFriendHit") then return end
                    local total_damage = dmg_info:get_field("_TotalDamage")
                    if total_damage and total_damage > 0 then
                        ComboMeter.on_hit(total_damage)
                    end
                end)
                _in_attack_hook = false
                captured_char = nil
                return retval
            end
        )
    end

    -- ── damage taken ──────────────────────────────────────
    local damage_method = hunter_type:get_method("evHit_Damage")
    if damage_method then
        sdk.hook(
            damage_method,
            function(args)
                state.hp_before_hit = nil
                state.hp_mgr_ref = nil
                if _in_damage_hook or not ComboMeter.config.enabled then return end
                local ok, this = pcall(function() return args[1] end)
                if not ok or not this then return end
                local ok2, is_master = pcall(function() return this:call("get_IsMaster") end)
                if not ok2 or not is_master then return end
                _in_damage_hook = true
                pcall(function()
                    local health = this:call("get_HunterHealth")
                    if not health then return end
                    local mgr = health:call("get_HealthMgr")
                    if not mgr then return end
                    local hp = mgr:call("get_Health")
                    if hp then
                        state.hp_before_hit = hp
                        state.hp_mgr_ref = mgr
                    end
                end)
                _in_damage_hook = false
            end,
            function(retval)
                if not state.hp_before_hit or not state.hp_mgr_ref then
                    state.hp_before_hit = nil
                    state.hp_mgr_ref = nil
                    return retval
                end
                if _in_damage_hook then return retval end
                _in_damage_hook = true
                pcall(function()
                    local hp_after = state.hp_mgr_ref:call("get_Health")
                    local max_hp = state.hp_mgr_ref:call("get_MaxHealth")
                    local damage = state.hp_before_hit - hp_after
                    if damage > 0 and max_hp and max_hp > 0 then
                        ComboMeter.on_damage_taken(damage, max_hp)
                    end
                end)
                _in_damage_hook = false
                state.hp_before_hit = nil
                state.hp_mgr_ref = nil
                return retval
            end
        )
    end

    -- ── per-frame update + draw ───────────────────────────
    local last_time = os.clock()
    re.on_frame(function()
        local now = os.clock()
        local dt = now - last_time
        last_time = now
        ComboMeter.update(dt)
        ComboMeter.draw()
    end)

    -- ── quest end reset ───────────────────────────────────
    --fires on quest complete fail and return to hub
    local quest_method = hunter_type:get_method("onSeamlessQuestEnd")
    if quest_method then
        sdk.hook(
            quest_method,
            nil,
            function(retval)
                ComboMeter.reset()
                return retval
            end
        )
    end
end

-- ─────────────────────────────────────────────
-- Imgui settings panel
-- ─────────────────────────────────────────────
re.on_draw_ui(function()
    if imgui.tree_node("DMC Style Meter") then
        local cfg = ComboMeter.config
        local changed, val

        changed, val = imgui.checkbox("Enabled", cfg.enabled)
        if changed then cfg.enabled = val end

        imgui.separator()
        imgui.text("Scoring")

        changed, val = imgui.slider_float("Hit Multiplier",       cfg.hit_multiplier, 0.1, 2.0)
        if changed then cfg.hit_multiplier = val end

        changed, val = imgui.slider_float("Hit Cap (per hit)",    cfg.hit_cap, 50, 500)
        if changed then cfg.hit_cap = val end

        changed, val = imgui.slider_float("Decay Rate (pts/sec)", cfg.decay_rate, 5, 100)
        if changed then cfg.decay_rate = val end

        changed, val = imgui.slider_float("Combo Window (sec)",   cfg.combo_window, 1, 15)
        if changed then cfg.combo_window = val end

        changed, val = imgui.slider_float("Damage Penalty Scale", cfg.penalty_scale, 100, 3000)
        if changed then cfg.penalty_scale = val end

        imgui.separator()
        imgui.text("Rank Thresholds")

        changed, val = imgui.slider_int("C", cfg.thresholds.C, 50,  500)
        if changed then cfg.thresholds.C = val end

        changed, val = imgui.slider_int("B", cfg.thresholds.B, 100, 1000)
        if changed then cfg.thresholds.B = val end

        changed, val = imgui.slider_int("A", cfg.thresholds.A, 200, 2000)
        if changed then cfg.thresholds.A = val end

        changed, val = imgui.slider_int("S", cfg.thresholds.S, 500, 5000)
        if changed then cfg.thresholds.S = val end

        imgui.separator()
        imgui.text("HUD Position")

        changed, val = imgui.slider_float("X (0-1)", cfg.hud_x, 0.0, 1.0)
        if changed then cfg.hud_x = val end

        changed, val = imgui.slider_float("Y (0-1)", cfg.hud_y, 0.0, 1.0)
        if changed then cfg.hud_y = val end

        imgui.separator()

        --live debug readout in settings panel
        imgui.text(string.format("Score: %.1f  |  Rank: %s  |  Hits: %d",
            state.score, state.rank, state.hit_count))

        if imgui.button("Reset Combo (debug)") then
            ComboMeter.reset()
        end

        imgui.tree_pop()
    end
end)

-- ─────────────────────────────────────────────
-- Bootstrap
-- ─────────────────────────────────────────────
ComboMeter.register_hooks()

return ComboMeter

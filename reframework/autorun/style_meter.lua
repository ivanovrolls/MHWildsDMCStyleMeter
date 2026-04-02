--dmc combo meter for monster hunter wilds (reframework)
--requires reframework + reframework direct2d plugin
--draw api pattern taken from my working swaxe hud rise mode

local ComboMeter = {}

-- ─────────────────────────────────────────────
-- Config
-- ─────────────────────────────────────────────
ComboMeter.config = {
    enabled = true,

    --skin: "dmc3" uses image assets, "default" uses built-in text renderer
    skin = "dmc3",

    --path to skin texture folder (relative to game root)
    --files expected:XDbg.png, Xfill.png, Xbg2.png, Xbghighlight.png, Xtext.png, Xtexthighlight.png
    skin_path = "C:/Program Files (x86)/Steam/steamapps/common/MonsterHunterWilds/reframework/images/dmc3/",--absolute path currently due to issues with relative paths

    --0.5 gives a 150x151px letter, native is too big
    image_scale = 0.5,

    --rank score thresholds (deliberately wider gaps at higher ranks)
    --combined with decay_scale this means high ranks are hard to reach but sticky once there
    thresholds = { D=0, C=150, B=400, A=800, S=1500, SS=3000, SSS=6000 },

    --points per hit = _TotalDamage * hit_multiplier, capped at hit_cap
    hit_multiplier = 8,
    hit_cap = 1500,

    --score decay per second when no hit lands (base rate, scaled by rank)
    decay_rate = 37.5,

    --decay multiplier per rank (lower = slower decay at high rank)
    decay_scale = {D=1.0, C=1.0, B=0.85, A=0.7, S=0.5, SS=0.35, SSS=0.2},

    --seconds of no hits before full score reset
    inactivity_reset = 10.0,

    --damage penalty = (incoming / maxHp) * penalty_scale subtracted from score
    --penalty = (damage / maxHp) * scale, so 100 scale = full HP bar wipes the meter
    penalty_scale = 300,

    --rank-change animation duration in seconds
    rank_anim_duration = 0.5,

    --seconds after sheathing before meter hides
    sheathe_hide_delay = 10.0,

    --seconds after sheathing before full reset
    sheathe_reset_delay = 15.0,

    hud_x = 1600,
    hud_y = 400,

    -- optional fine-tuning
    letter_offset_x = 0,
    letter_offset_y = 0,
    text_offset_x = 0,
    text_offset_y = 0,
    mask_color = 0xFF000000,

    --bonus points awarded for skilful actions
    bonus_perfect_dodge = 120,
    bonus_guard_point = 200,
    bonus_perfect_guard = 80,
    bonus_wyvern_riding = 60,
    bonus_ls_counter = 250,
    bonus_sa_counter = 700,
    bonus_power_clash = 300,
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
    visible = false,
    sheathed = false,
    sheathe_time = nil,
    hp_before_hit = nil,
    hp_mgr_ref = nil,
    stock_pre = nil,
}

-- ─────────────────────────────────────────────
-- Image asset tables (populated in d2d init)
-- ─────────────────────────────────────────────
--each rank has one image of each
local images = {}
local images_loaded = false
local images_attempted = false

--font objects for default skin fallback
local font_rank = nil
local font_label = nil
local font_hits = nil

-- ─────────────────────────────────────────────
-- Native image dimensions (DONT TOUCH)
-- ─────────────────────────────────────────────
local IMG_LETTER_W = 301   --Xbg.png and Xfill.png width
local IMG_LETTER_H = 303   --Xbg.png and Xfill.png height
local IMG_BG2_W = 2100  --Xbg2.png width
local IMG_BG2_H = 2100  --Xbg2.png height
local IMG_TEXT_W = 1000  --Xtext.png width
local IMG_TEXT_H = 243   --Xtext.png height

-- ─────────────────────────────────────────────
-- Colour helpers for default skin
-- ─────────────────────────────────────────────
local function argb(a, r, g, b)
    return (a << 24) | (r << 16) | (g << 8) | b
end

local RANK_COLORS = {
    D = argb(255, 170, 170, 170),
    C = argb(255, 68, 204, 255),
    B = argb(255, 68, 255, 136),
    A = argb(255, 255, 204, 0),
    S = argb(255, 255, 51, 0),
    SS = argb(255, 255, 100, 220),
    SSS = argb(255, 255, 215, 0),
}

local BAR_COLORS = {
    D = argb(255, 102, 102, 102),
    C = argb(255, 34, 136, 204),
    B = argb(255, 34, 170, 85),
    A = argb(255, 187, 153, 0),
    S = argb(255, 204, 34, 0),
    SS = argb(255, 200, 60, 180),
    SSS = argb(255, 220, 170, 0),
}

local RANK_LABELS = {
    D = "DULL",
    C = "COME ON",
    B = "BADASS",
    A = "AWESOME!",
    S = "STYLISH!!",
    SS = "SHOW OFF!!",
    SSS = "SMOKIN' SEXY STYLE!!!",
}

local RANK_ORDER = {"D", "C", "B", "A", "S", "SS", "SSS"}

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────
local function score_to_rank(score) --converts a raw score into a rank string based on configured thresholds
    local t = ComboMeter.config.thresholds
    if score >= t.SSS then return "SSS"
    elseif score >= t.SS  then return "SS"
    elseif score >= t.S   then return "S"
    elseif score >= t.A   then return "A"
    elseif score >= t.B   then return "B"
    elseif score >= t.C   then return "C"
    else return "D" end
end

local function next_threshold(rank) --returns score threshold required to reach next rank
    local t = ComboMeter.config.thresholds
    return ({ D=t.C, C=t.B, B=t.A, A=t.S, S=t.SS, SS=t.SSS, SSS=t.SSS })[rank] or t.SSS
end

local function cur_threshold(rank) --returns minimum score required to be within current rank
    local t = ComboMeter.config.thresholds
    return ({ D=t.D, C=t.C, B=t.B, A=t.A, S=t.S, SS=t.SS, SSS=t.SSS })[rank] or 0
end

local function fill_fraction() --calculates normalized progress between current rank and next rank thresholds
    local rank = state.rank
    local nxt = next_threshold(rank)
    local cur = cur_threshold(rank)
    if nxt <= cur then return 1.0 end
    return math.min(1.0, (state.score - cur) / (nxt - cur))
end

local function update_rank() --updates player's rank based on current score, triggers rank change if needed
    local new_rank = score_to_rank(state.score)
    if new_rank ~= state.rank then
        state.prev_rank = state.rank
        state.rank = new_rank
        state.rank_changed = true
        state.rank_anim_t = ComboMeter.config.rank_anim_duration
    end
end

-- ─────────────────────────────────────────────
-- Image loading; pre-laods images into a table for quick rendering
-- ─────────────────────────────────────────────
local function load_images()
    if images_attempted then return end --stop multiple load attempts
    images_attempted = true

    local path = ComboMeter.config.skin_path
    local slots = {"bg", "fill", "bg2", "bghighlight", "text", "texthighlight"}
    local loaded = true
    log.info("[StyleMeter] loading images from path: " .. tostring(path))

    for _, rank in ipairs(RANK_ORDER) do --for each rank
        images[rank] = {} --image table
        for _, slot in ipairs(slots) do
            local filepath = path .. rank .. slot .. ".png" --build filepath
            local ok, img = pcall(function() return d2d.Image.new(filepath) end) --attempt to load it
            if ok and img then
                images[rank][slot] = img --put in table if successful
            else
                log.warn("[StyleMeter] failed to load: " .. filepath)
                loaded = false
            end
        end
    end

    images_loaded = loaded --store overall load result
    if loaded then
        log.info("[StyleMeter] all dmc3 images loaded successfully")
    else
        log.warn("[StyleMeter] some images failed to load, falling back to default skin")
        ComboMeter.config.skin = "default"
    end
end

-- ─────────────────────────────────────────────
-- Core logic
-- ─────────────────────────────────────────────
function ComboMeter.on_hit(total_damage)
    if not ComboMeter.config.enabled then return end
    local cfg = ComboMeter.config
    local now = os.clock()

    if not state.active then
        state.active = true
        state.visible = true
    end

    state.sheathed = false
    state.sheathe_time = nil
    state.visible = true

    local pts = math.min(total_damage * cfg.hit_multiplier, cfg.hit_cap)
    state.score = state.score + pts
    state.hit_count = state.hit_count + 1
    state.last_hit_time = now
    update_rank()
end

function ComboMeter.on_damage_taken(damage, max_hp)
    if not ComboMeter.config.enabled or not state.active then return end
    if damage <= 0 then return end
    local penalty = (damage / max_hp) * ComboMeter.config.penalty_scale
    state.score = math.max(0, state.score - penalty)
    update_rank()
end

function ComboMeter.on_bonus(points, label)
    if not ComboMeter.config.enabled then return end
    if not state.active then
        state.active = true
        state.visible = true
        state.last_hit_time = os.clock()
    end
    state.score = state.score + points
    state.last_hit_time = os.clock()
    update_rank()
    log.info("[StyleMeter] bonus: " .. label .. " +" .. tostring(points))
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
    state.visible = false
    state.sheathed = false
    state.sheathe_time = nil
    state.hp_before_hit = nil
    state.hp_mgr_ref = nil
    state.stock_pre = nil
end

-- ─────────────────────────────────────────────
-- Update
-- ─────────────────────────────────────────────
function ComboMeter.update(dt)
    if not ComboMeter.config.enabled then return end

    local now = os.clock()
    local cfg = ComboMeter.config

    --sheathe timer progression
    if state.active and state.sheathed and state.sheathe_time then
        local elapsed = now - state.sheathe_time
        if elapsed >= cfg.sheathe_hide_delay then
            state.visible = false
        end
        if elapsed >= cfg.sheathe_reset_delay then
            ComboMeter.reset()
            return
        end
    end

    if not state.active then return end

    local idle_time = now - state.last_hit_time

    --full inactivity reset
    if state.active and idle_time >= cfg.inactivity_reset then
        ComboMeter.reset()
        return
    end

    --score decay scaled by current rank
    if idle_time > 0.1 then
        local decay_mult = (cfg.decay_scale and cfg.decay_scale[state.rank]) or 1.0
        state.score = math.max(0, state.score - cfg.decay_rate * decay_mult * dt)
        update_rank()
    end

    --animation timer
    if state.rank_anim_t > 0 then
        state.rank_anim_t = math.max(0, state.rank_anim_t - dt)
        if state.rank_anim_t == 0 then
            state.rank_changed = false
        end
    end
end

-- ─────────────────────────────────────────────
-- Draw: DMC3 image skin
-- ─────────────────────────────────────────────
local function draw_dmc3()
    local cfg = ComboMeter.config
    local scale = cfg.image_scale
    local rank = state.rank
    local imgs = images[rank]
    if not imgs then return end

    --scaled dimensions (must be calculate before using lh)
    local lw = math.floor(IMG_LETTER_W * scale)
    local lh = math.floor(IMG_LETTER_H * scale)
    local bw2 = math.floor(IMG_BG2_W * scale)
    local bh2 = math.floor(IMG_BG2_H * scale)
    local tw = math.floor(IMG_TEXT_W * scale)
    local th = math.floor(IMG_TEXT_H * scale)

    --apply offsets
    local bx = cfg.hud_x + cfg.letter_offset_x
    local by = cfg.hud_y + cfg.letter_offset_y
    local text_x = bx + math.floor(lw * 0.63) + cfg.text_offset_x
    local text_y = by + math.floor(lh * 0.25) + cfg.text_offset_y

    local bg2_x = bx - math.floor((bw2 - lw) / 2)
    local bg2_y = by - math.floor((bh2 - lh) / 2)

    local highlight_alpha = 255
    if state.rank_anim_t > 0 then
        local t = state.rank_anim_t / cfg.rank_anim_duration
        highlight_alpha = math.floor(255 * t)
    end

    local frac = fill_fraction()

    local bar_width = math.floor(lw * 0.8)
    local bar_height = 8
    local bar_x = bx + math.floor((lw - bar_width) / 2)
    local bar_y = by + lh + 5

    local bar_color
    if frac < 0.25 then
        bar_color = argb(255, 255, 0, 0)
    else
        bar_color = argb(255, 255, 255, 0)
    end

    local bar_bg_color = argb(255, 40, 40, 40)

    if imgs.bg2 then d2d.image(imgs.bg2, bg2_x, bg2_y, bw2, bh2, 255) end
    if imgs.bg  then d2d.image(imgs.bg,  bx, by, lw, lh, 255) end
    if imgs.fill then d2d.image(imgs.fill, bx, by, lw, lh, 255) end
    if imgs.bghighlight then d2d.image(imgs.bghighlight, bx, by, lw, lh, highlight_alpha) end
    if imgs.texthighlight then d2d.image(imgs.texthighlight, text_x, text_y, tw, th, highlight_alpha) end
    if imgs.text then d2d.image(imgs.text, text_x, text_y, tw, th, 255) end

    d2d.fill_rect(bar_x, bar_y, bar_width, bar_height, bar_bg_color)
    if frac > 0 then
        local fill_width = math.floor(bar_width * frac)
        d2d.fill_rect(bar_x, bar_y, fill_width, bar_height, bar_color)
    end

    if font_hits then
        d2d.text(font_hits,
            string.format("HITS  %d", state.hit_count),
            bx, bar_y + bar_height + 5,
            argb(255, 204, 204, 204)
        )
    end
end

-- ─────────────────────────────────────────────
-- Draw: default text skin (fallback)
-- ─────────────────────────────────────────────
local function draw_default()
    local cfg = ComboMeter.config
    local base_x = cfg.hud_x
    local base_y = cfg.hud_y

    --elastic pop animation on rank change
    local anim_scale = 1.0
    if state.rank_anim_t > 0 then
        local t = 1.0 - (state.rank_anim_t / cfg.rank_anim_duration)
        anim_scale = 1.0 + 0.4 * math.exp(-t * 8) * math.cos(t * 20)
    end

    --resolve colours and label for current rank
    local rank = state.rank
    local rank_col = RANK_COLORS[rank] or argb(255,255,255,255)
    local bar_col = BAR_COLORS[rank] or argb(255,136,136,136)
    local label = RANK_LABELS[rank] or rank
    local shadow = argb(170, 0, 0, 0)

    --draw rank letter with drop shadow
    local lx = base_x
    local ly = base_y
    if font_rank then
        d2d.text(font_rank, rank, lx + 3, ly + 3, shadow)
        d2d.text(font_rank, rank, lx, ly, rank_col)
    end

    --draw style label below the rank letter, also with shadow
    local label_y = ly + 100
    if font_label then
        d2d.text(font_label, label, lx + 1, label_y + 1, shadow)
        d2d.text(font_label, label, lx, label_y, rank_col)
    end

    --draw progress bar: dark background track + coloured fill
    --ill width is proportional to progress toward next rank threshold
    local bar_w = 120
    local bar_h = 8
    local bar_x = base_x
    local bar_y = label_y + 24
    local frac = fill_fraction()
    d2d.fill_rect(bar_x, bar_y, bar_w, bar_h, argb(255,34,34,34))-- track
    d2d.fill_rect(bar_x, bar_y, math.floor(bar_w * frac), bar_h, bar_col) -- fill

    --draw hit counter below the bar
    if font_hits then
        d2d.text(font_hits,
            string.format("HITS  %d", state.hit_count),
            bar_x, bar_y + bar_h + 6,
            argb(255, 204, 204, 204)
        )
    end
end

-- ─────────────────────────────────────────────
-- Draw dispatcher
-- ─────────────────────────────────────────────
function ComboMeter.draw()
    if not ComboMeter.config.enabled then return end
    if not state.visible then return end

    local use_images = (ComboMeter.config.skin == "dmc3") and images_loaded

    if use_images then
        draw_dmc3()
    else
        if not font_rank then return end
        draw_default()
    end
end

-- ─────────────────────────────────────────────
-- REFramework hooks
-- ─────────────────────────────────────────────
function ComboMeter.register_hooks()
    local hunter_type = sdk.find_type_definition("app.HunterCharacter")
    if not hunter_type then
        log.warn("[StyleMeter] app.HunterCharacter not found, hooks skipped")
        return
    end

    local _in_damage_hook = false

    --damage dealt
    local attack_method = hunter_type:get_method("evHit_AttackPostProcess")
    if attack_method then
        local captured_char = nil
        sdk.hook(
            attack_method,
            function(args)
                local this = sdk.to_managed_object(args[2])
                captured_char = this or nil
            end,
            function(retval)
                local char = captured_char
                captured_char = nil
                if not char or not ComboMeter.config.enabled then return retval end
                pcall(function()
                    local stock = char:call("get_StockDamage")
                    if not stock then return end

                    local dmg_info = stock:call("get_ApplyDamageInfo")
                    if not dmg_info then
                        stock:call("selectApplyDamageInfo")
                        dmg_info = stock:call("get_ApplyDamageInfo")
                    end
                    if not dmg_info then return end
                    if dmg_info:get_field("_IsFriendHit") then return end

                    local total_damage = dmg_info:get_field("_TotalDamage")
                    if total_damage and total_damage > 0 then
                        ComboMeter.on_hit(total_damage)
                        --wyvern riding bonus on top of normal hit
                        local ok_ride, is_riding = pcall(function()
                            return char:call("get_IsRiding")
                        end)
                        if ok_ride and is_riding then
                            ComboMeter.on_bonus(ComboMeter.config.bonus_wyvern_riding, "wyvern riding")
                        end
                    end
                end)
                return retval
            end
        )
    end

    --damage taken (+ perfect dodge / guard detection)
    local damage_method = hunter_type:get_method("evHit_Damage")
    if damage_method then
        sdk.hook(
            damage_method,
            function(args)
                state.hp_before_hit = nil
                state.hp_mgr_ref = nil
                state.stock_pre = nil
                if _in_damage_hook or not ComboMeter.config.enabled then return end
                local this = sdk.to_managed_object(args[2])
                if not this then return end
                local ok, is_master = pcall(function() return this:call("get_IsMaster") end)
                if not ok or not is_master then return end
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
                    local stock = this:call("get_StockDamage")
                    if stock then state.stock_pre = stock end
                end)
                _in_damage_hook = false
            end,
            function(retval)
                if not state.hp_before_hit or not state.hp_mgr_ref then
                    state.hp_before_hit = nil
                    state.hp_mgr_ref = nil
                    state.stock_pre = nil
                    return retval
                end
                if _in_damage_hook then return retval end
                _in_damage_hook = true
                pcall(function()
                    local cfg = ComboMeter.config
                    local hp_after = state.hp_mgr_ref:call("get_Health")
                    local max_hp = state.hp_mgr_ref:call("get_MaxHealth")
                    local damage = state.hp_before_hit - hp_after

                    if damage > 0 and max_hp and max_hp > 0 then
                        ComboMeter.on_damage_taken(damage, max_hp)
                    elseif damage == 0 and state.stock_pre then
                        --zero damage: check for guard or perfect dodge
                        local dmg_info = state.stock_pre:call("get_ApplyDamageInfo")
                        if not dmg_info then
                            state.stock_pre:call("selectApplyDamageInfo")
                            dmg_info = state.stock_pre:call("get_ApplyDamageInfo")
                        end
                        if dmg_info then
                            local guard_reaction = dmg_info:get_field("_GuardReaction")
                            if guard_reaction and guard_reaction > 0 then
                                local ok_gp, gp_val = pcall(function()
                                    return state.stock_pre:call("calcGuardReactionTech")
                                end)
                                if ok_gp and gp_val and gp_val ~= 0 then
                                    ComboMeter.on_bonus(cfg.bonus_guard_point, "guard point")
                                else
                                    ComboMeter.on_bonus(cfg.bonus_perfect_guard, "perfect guard")
                                end
                            end
                            --perfect dodge disabled: zero-damage non-guard events are too broad
                            --will re-enable once a more precise i-frame detection method is found
                        end
                    end
                end)
                _in_damage_hook = false
                state.hp_before_hit = nil
                state.hp_mgr_ref = nil
                state.stock_pre = nil
                return retval
            end
        )
    end

    --per-frame update + weapon sheathe pol
    local last_time = os.clock()
    re.on_frame(function()
        local now = os.clock()
        local dt = now - last_time
        last_time = now

        local pm = sdk.get_managed_singleton("app.PlayerManager")
        if pm then
            local info = pm:call("getMasterPlayerInfo")
            if info then
                local character = info:call("get_Character")
                if character then
                    local ok, is_weapon_on = pcall(function()
                        return character:call("get_IsWeaponOn")
                    end)
                    if ok then
                        if not is_weapon_on and not state.sheathed then
                            state.sheathed = true
                            state.sheathe_time = now
                            if state.active then state.visible = false end
                        elseif is_weapon_on and state.sheathed then
                            state.sheathed = false
                            state.sheathe_time = nil
                            if state.active then state.visible = true end
                        end
                    end
                end
            end
        end

        ComboMeter.update(dt)
    end)

    --d2d draw registration
    d2d.register(
        function()
            font_rank = d2d.Font.new("Arial Bold", 96)
            font_label = d2d.Font.new("Arial Bold", 18)
            font_hits = d2d.Font.new("Arial",      14)
        end,
        function()
            if not images_attempted and ComboMeter.config.skin == "dmc3" then
                load_images()
            end
            ComboMeter.draw()
        end
    )

    --quest end reset
    local quest_method = hunter_type:get_method("onSeamlessQuestEnd")
    if quest_method then
        sdk.hook(quest_method, nil, function(retval)
            ComboMeter.reset()
            return retval
        end)
    end

    --LS counter / power clash exploration
    --startDKCounterBuff exists but did not fire on IAI or helm breaker in testing
    --Dumping all methods on the LS-specific action type and power clash type at startup

    --doHitMikiri = offset/counter success
    --doHitMikiri might fire on successful counters across weapons but so far only on LS
    --LS IAI counte helm splitter counter window
    --Other weapons with offset attacks (SA, CB, etc.)
    --Awards the ls_counter bonus on any successful mikiri/offset hit
    local mikiri_method = hunter_type:get_method("doHitMikiri")
    if mikiri_method then
        sdk.hook(
            mikiri_method,
            function(args)
                local this = sdk.to_managed_object(args[2])
                if not this then return end
                local ok, is_master = pcall(function() return this:call("get_IsMaster") end)
                if not ok or not is_master then return end
                ComboMeter.on_bonus(ComboMeter.config.bonus_ls_counter, "offset/mikiri counter")
            end,
            nil
        )
        log.info("[StyleMeter] hooked doHitMikiri for offset counter detection")
    else
        log.warn("[StyleMeter] doHitMikiri not found")
    end

    log.info("[StyleMeter] LS/clash type exploration done (check log)")
end

-- ─────────────────────────────────────────────
-- ImGui settings panel
-- ─────────────────────────────────────────────
re.on_draw_ui(function()
    if imgui.tree_node("DMC Style Meter") then
        local cfg = ComboMeter.config
        local changed, val

        changed, val = imgui.checkbox("Enabled", cfg.enabled)
        if changed then cfg.enabled = val end

        imgui.separator()
        imgui.text("Skin")

        local skin_options = { "default", "dmc3" }
        local current_skin_idx = (cfg.skin == "dmc3") and 1 or 0
        changed, val = imgui.combo("Skin", current_skin_idx, skin_options)
        if changed then
            cfg.skin = skin_options[val + 1]
            images_attempted = false
            images_loaded = false
        end
        if not images_loaded and cfg.skin == "dmc3" then
            imgui.text("!! Reload scripts to apply skin !!")
        end

        changed, val = imgui.slider_float("Image Scale", cfg.image_scale, 0.1, 2.0)
        if changed then cfg.image_scale = val end

        imgui.text("Images loaded: " .. tostring(images_loaded))

        imgui.separator()
        imgui.text("Scoring")

        changed, val = imgui.slider_float("Hit Multiplier", cfg.hit_multiplier, 0.1, 5.0)
        if changed then cfg.hit_multiplier = val end

        changed, val = imgui.slider_float("Hit Cap (per hit)", cfg.hit_cap, 50, 2000)
        if changed then cfg.hit_cap = val end

        changed, val = imgui.slider_float("Decay Rate (pts/sec)", cfg.decay_rate, 1, 100)
        if changed then cfg.decay_rate = val end

        changed, val = imgui.slider_float("Inactivity Reset (sec)", cfg.inactivity_reset, 5, 60)
        if changed then cfg.inactivity_reset = val end

        changed, val = imgui.slider_float("Damage Penalty Scale", cfg.penalty_scale, 0, 500)
        if changed then cfg.penalty_scale = val end

        imgui.separator()
        imgui.text("Rank Decay Scale (lower = slower decay at that rank)")
        for _, r in ipairs(RANK_ORDER) do
            if cfg.decay_scale and cfg.decay_scale[r] then
                changed, val = imgui.slider_float(r, cfg.decay_scale[r], 0.05, 1.5)
                if changed then cfg.decay_scale[r] = val end
            end
        end

        imgui.separator()
        imgui.text("Bonus Actions")

        changed, val = imgui.slider_int("Perfect Dodge Bonus", cfg.bonus_perfect_dodge, 0, 500)
        if changed then cfg.bonus_perfect_dodge = val end

        changed, val = imgui.slider_int("Perfect Guard Bonus", cfg.bonus_perfect_guard, 0, 500)
        if changed then cfg.bonus_perfect_guard = val end

        changed, val = imgui.slider_int("Guard Point Bonus", cfg.bonus_guard_point,   0, 500)
        if changed then cfg.bonus_guard_point = val end

        changed, val = imgui.slider_int("Wyvern Riding Bonus", cfg.bonus_wyvern_riding, 0, 200)
        if changed then cfg.bonus_wyvern_riding = val end

        changed, val = imgui.slider_int("LS Counter Bonus", cfg.bonus_ls_counter, 0, 600)
        if changed then cfg.bonus_ls_counter = val end

        changed, val = imgui.slider_int("SA Sword Counter Bonus", cfg.bonus_sa_counter, 0, 1000)
        if changed then cfg.bonus_sa_counter = val end

        changed, val = imgui.slider_int("Power Clash Win Bonus", cfg.bonus_power_clash, 0, 600)
        if changed then cfg.bonus_power_clash = val end

        imgui.separator()
        imgui.text("Hook Exploration")
        if imgui.button("Dump ALL HunterCharacter methods to log") then
            local ht = sdk.find_type_definition("app.HunterCharacter")
            if ht then
                log.info("=== ALL HunterCharacter methods ===")
                for _, m in ipairs(ht:get_methods()) do
                    log.info("  " .. m:get_name())
                end
                log.info("===================================")
            end
        end

        if imgui.button("Dump weapon object methods (needs active hunt)") then
            local pm = sdk.get_managed_singleton("app.PlayerManager")
            if pm then
                local info = pm:call("getMasterPlayerInfo")
                if info then
                    local character = info:call("get_Character")
                    if character then
                        local weapon = character:call("get_Weapon")
                        if weapon then
                            local t = weapon:get_type_definition()
                            log.info("=== Weapon type: " .. t:get_full_name() .. " ===")
                            local keywords = {
                                "counter", "Counter", "offset", "Offset",
                                "evHit", "doHit", "onHit", "onSuccess",
                                "Slash", "slash", "Burst", "burst",
                                "Sword", "sword", "Axe", "axe",
                                "Guard", "guard", "Parry", "parry",
                            }
                            for _, m in ipairs(t:get_methods()) do
                                local name = m:get_name()
                                for _, kw in ipairs(keywords) do
                                    if name:find(kw) then
                                        log.info("  " .. name)
                                        break
                                    end
                                end
                            end
                            log.info("==========================================")
                        else
                            log.info("[StyleMeter] no weapon found - draw your weapon first")
                        end
                    end
                end
            end
        end
        imgui.text("Draw weapon first, then press to dump weapon methods")

        if imgui.button("Dump HunterCharacter components (needs active hunt)") then
            local pm = sdk.get_managed_singleton("app.PlayerManager")
            if pm then
                local info = pm:call("getMasterPlayerInfo")
                if info then
                    local character = info:call("get_Character")
                    if character then
                        log.info("=== HunterCharacter components ===")
                        --try get_Components or iterating via transform
                        local ok, comps = pcall(function()
                            return character:call("get_Components")
                        end)
                        if ok and comps then
                            local count = comps:call("get_Count")
                            for i = 0, count - 1 do
                                local comp = comps:call("get_Item", i)
                                if comp then
                                    local t = comp:get_type_definition()
                                    if t then
                                        local n = t:get_full_name()
                                        if n:find("Wp") or n:find("Weapon") or n:find("weapon")
                                            or n:find("Clash") or n:find("clash")
                                            or n:find("Counter") or n:find("counter")
                                            or n:find("LongSword") or n:find("Sword")
                                            or n:find("Action") or n:find("Combat") then
                                            log.info("  component: " .. n)
                                        end
                                    end
                                end
                            end
                        else
                            --fallback: dump via game object component list
                            local go_ok, go = pcall(function() return character:call("get_GameObject") end)
                            if go_ok and go then
                                log.info("  (via GameObject)")
                                local c_ok, c = pcall(function() return go:call("get_Components") end)
                                if c_ok and c then
                                    local cnt = c:call("get_Count")
                                    for i = 0, cnt - 1 do
                                        local comp = c:call("get_Item", i)
                                        if comp then
                                            local t = comp:get_type_definition()
                                            if t then log.info("  " .. t:get_full_name()) end
                                        end
                                    end
                                end
                            end
                        end
                        log.info("==================================")
                    else
                        log.info("[StyleMeter] no character - must be in an active hunt")
                    end
                end
            end
        end
        imgui.text("(check REFramework log after pressing)")

        imgui.separator()
        imgui.text("Rank Thresholds")

        changed, val = imgui.slider_int("C",   cfg.thresholds.C,   50,   500)
        if changed then cfg.thresholds.C = val end

        changed, val = imgui.slider_int("B",   cfg.thresholds.B,   100,  1000)
        if changed then cfg.thresholds.B = val end

        changed, val = imgui.slider_int("A",   cfg.thresholds.A,   200,  2000)
        if changed then cfg.thresholds.A = val end

        changed, val = imgui.slider_int("S",   cfg.thresholds.S,   500,  3000)
        if changed then cfg.thresholds.S = val end

        changed, val = imgui.slider_int("SS",  cfg.thresholds.SS,  1000, 8000)
        if changed then cfg.thresholds.SS = val end

        changed, val = imgui.slider_int("SSS", cfg.thresholds.SSS, 2000, 12000)
        if changed then cfg.thresholds.SSS = val end

        imgui.separator()
        imgui.text("Visibility")

        changed, val = imgui.slider_float("Sheathe Hide Delay (sec)",  cfg.sheathe_hide_delay,  1, 30)
        if changed then cfg.sheathe_hide_delay = val end

        changed, val = imgui.slider_float("Sheathe Reset Delay (sec)", cfg.sheathe_reset_delay, 5, 60)
        if changed then cfg.sheathe_reset_delay = val end

        imgui.separator()
        imgui.text("HUD Position (pixels)")

        changed, val = imgui.drag_int("X", cfg.hud_x, 1, 0, 3840)
        if changed then cfg.hud_x = val end

        changed, val = imgui.drag_int("Y", cfg.hud_y, 1, 0, 2160)
        if changed then cfg.hud_y = val end

        imgui.separator()
        imgui.text("Image Fine-tuning")

        changed, val = imgui.drag_int("Letter X Offset", cfg.letter_offset_x, 1, -200, 200)
        if changed then cfg.letter_offset_x = val end

        changed, val = imgui.drag_int("Letter Y Offset", cfg.letter_offset_y, 1, -200, 200)
        if changed then cfg.letter_offset_y = val end

        changed, val = imgui.drag_int("Text X Offset", cfg.text_offset_x, 1, -200, 200)
        if changed then cfg.text_offset_x = val end

        changed, val = imgui.drag_int("Text Y Offset", cfg.text_offset_y, 1, -200, 200)
        if changed then cfg.text_offset_y = val end

        local hex_color = string.format("%08X", cfg.mask_color)
        changed, hex_color = imgui.input_text("Mask Colour (ARGB Hex)", hex_color)
        if changed and #hex_color == 8 then
            local ok, v = pcall(function() return tonumber(hex_color, 16) end)
            if ok and v then cfg.mask_color = v end
        end
        imgui.text("Format: AARRGGBB (e.g., FF000000 = black)")

        if imgui.button("Reset Offsets") then
            cfg.letter_offset_x = 0
            cfg.letter_offset_y = 0
            cfg.text_offset_x = 0
            cfg.text_offset_y = 0
            cfg.mask_color = 0xFF000000
        end

        imgui.separator()
        imgui.text(string.format("Score: %.1f  |  Rank: %s  |  Hits: %d",
            state.score, state.rank, state.hit_count))
        imgui.text(string.format("Visible: %s  |  Sheathed: %s",
            tostring(state.visible), tostring(state.sheathed)))

        if imgui.button("Reset Combo (debug)") then
            ComboMeter.reset()
        end

        if imgui.button("Dump d2d functions") then
            log.info("=== d2d table dump ===")
            for k, v in pairs(d2d) do
                log.info("d2d." .. tostring(k) .. " = " .. type(v))
            end
            if d2d.Image then
                log.info("--- d2d.Image sub-table ---")
                for k, v in pairs(d2d.Image) do
                    log.info("d2d.Image." .. tostring(k) .. " = " .. type(v))
                end
            else
                log.info("d2d.Image does not exist")
            end
            log.info("========================")
        end

        imgui.tree_pop()
    end
end)

-- ─────────────────────────────────────────────
-- SA sword counter hook
-- Must be at module level, not nested inside register_hooks,
-- so pre-hook callbacks fire correctly
-- ─────────────────────────────────────────────
local sa_hook_installed = false
local sa_hit_pre_time = 0

re.on_frame(function()
    if sa_hook_installed then return end
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    if not pm then return end
    local info = pm:call("getMasterPlayerInfo")
    if not info then return end
    local char = info:call("get_Character")
    if not char then return end
    local h = char:call("get_WeaponHandling")
    if not h then return end

    local t = h:get_type_definition()

    local pre_m = t:get_method("doOnHit_AttackPre")
    if pre_m then
        sdk.hook(pre_m, function(args)
            sa_hit_pre_time = os.clock()
        end, nil)
    end

    local awake_m = t:get_method("addSwordAwakeGauge")
    if awake_m then
        sdk.hook(awake_m, function(args)
            if not ComboMeter.config.enabled then return end
            local now = os.clock()
            if (now - sa_hit_pre_time) > 0.016 then
                ComboMeter.on_bonus(ComboMeter.config.bonus_sa_counter, "SA sword counter")
            end
        end, nil)
    end

    sa_hook_installed = true
    log.info("[StyleMeter] SA sword counter hooks installed")
end)

-- ─────────────────────────────────────────────
-- Bootstrap
-- ─────────────────────────────────────────────
ComboMeter.register_hooks()

return ComboMeter
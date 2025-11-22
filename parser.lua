--[[
  MIDI 音符识别器
  使用 CC: Tweaked 的 io 库读取 MIDI 二进制文件，解析 Note On/Off 事件，
  提取完整的音高名称和八度 (例如: C#4)，并将 Delta Time 转换为秒。
  
  核心改进：
  1. 实现了多音轨事件的合并和绝对时间排序，确保同步播放。
  2. 增加了 Note Off 事件处理，确保音符能够停止。
  3. 改进了 Set Tempo 事件的处理，确保节奏变化在正确的时间点生效。
  4. 【新增】支持三个独立的八度音高 (36个继电器)。

  注意：位操作符（&）已替换为算术和取模运算，以保持与标准 Lua 5.1/5.2 的兼容性。
--]]

local FILENAME = "2.mid"
local INDEX_START = 39  -- 为第一个连接的id-1 (第一个继电器ID将是 INDEX_START + 1)

-- 定义支持的音高范围 (例如：从 C3 到 B5，共 36 个音符)
local LOWEST_SUPPORTED_PITCH = 48 -- C3
local HIGHEST_SUPPORTED_PITCH = 83 -- B5

-- 完整的音名映射 (包含升降号)
local NOTE_NAMES_VERBOSE = {
    [0] = "C", [1] = "C#", [2] = "D", [3] = "D#", [4] = "E", [5] = "F",
    [6] = "F#", [7] = "G", [8] = "G#", [9] = "A", [10] = "A#", [11] = "B"
}

-- 存储所有轨道合并后的、带时间戳的事件列表
local event_list = {}

--- 将大端字节串转换为整数
-- @param str string 包含字节的字符串
-- @return number 转换后的整数
local function bytes_to_int(str)
    local value = 0
    -- MIDI 使用大端字节序 (Big Endian)
    for i = 1, #str do
        local byte = string.byte(str, i)
        value = value * 256 + byte
    end
    return value
end

--- 读取可变长度量 (VLQ)，用于 Delta Time 和某些 Meta Event 的长度
-- @param file io.Handle 文件句柄
-- @return number VLQ 整数值
local function read_vlq(file)
    local value = 0
    local byte
    repeat
        -- 读取单个字节
        local byte_char = file:read(1)
        if not byte_char then return nil end

        byte = string.byte(byte_char)
        -- 将值向左移动 7 位，并加上当前字节的低 7 位
        value = value * 128 + (byte % 128)
    -- 如果最高位为 0，则字节值 < 128
    until byte < 128 
    return value
end


--- 主解析函数
local function parseMidi()
    -- 清空事件列表，以防重复调用
    event_list = {} 
    
    local file, err = io.open(FILENAME, "rb")
    if not file then
        print("ERROR: Could not open file " .. FILENAME .. ": " .. tostring(err))
        return
    end

    print("--- Parsing MIDI file: " .. FILENAME .. " ---")
    
    -- 1. 解析 MIDI Header Chunk (MThd)
    local header_id = file:read(4) -- 'MThd'
    local header_size_str = file:read(4) -- 6 (固定长度)
    local format_str = file:read(2)
    local num_tracks_str = file:read(2)
    local division_str = file:read(2)
    
    if header_id ~= "MThd" or not header_size_str then
        print("ERROR: File is not a valid MIDI file or is too short.")
        file:close()
        return
    end

    local header_size = bytes_to_int(header_size_str)
    local format = bytes_to_int(format_str)
    local num_tracks = bytes_to_int(num_tracks_str)
    local division = bytes_to_int(division_str) 

    -- 检查 Division 的高位，确保是 TPQN 格式 (Ticks Per Quarter Note)
    local tpqn_division = division
    if tpqn_division >= 0x8000 then
        print("WARNING: SMPTE time code detected (not TPQN). Tempo calculation may be inaccurate.")
        tpqn_division = tpqn_division % 0x8000
    end
    
    -- 默认的 Microseconds Per Quarter Note (MPQN) - 120 BPM
    local default_mpqn = 500000 

    -- 首次 Set Tempo 事件 (0 ticks, 默认 120 BPM)
    table.insert(event_list, {
        type = "tempo",
        time_ticks = 0,
        mpqn = default_mpqn
    })

    print(string.format("MIDI Format: %d | Num Tracks: %d | Ticks/QN: %d", format, num_tracks, tpqn_division))
    print(string.format("Supported Pitch Range: %d (C%%d) to %d (B%%d). Relays %d to %d.", 
                        LOWEST_SUPPORTED_PITCH, HIGHEST_SUPPORTED_PITCH, INDEX_START + 1, INDEX_START + (HIGHEST_SUPPORTED_PITCH - LOWEST_SUPPORTED_PITCH + 1)))
    print("---------------------------------------")
    
    -- 2. 解析 MIDI Track Chunks (MTrk)
    local total_notes_found = 0

    for track_idx = 1, num_tracks do
        print(string.format(">>> Processing Track #%d <<<", track_idx))

        local track_id = file:read(4) -- 'MTrk'
        local track_size_str = file:read(4)

        if track_id ~= "MTrk" or not track_size_str then
            print("WARNING: Expected MTrk identifier, but file may have ended or format is incorrect.")
            break
        end

        local track_size = bytes_to_int(track_size_str)
        local track_start_pos = file:seek("cur") -- 记录轨道数据开始的位置

        local running_status = 0
        local notes_in_track = 0
        local track_time_ticks = 0 -- 轨道绝对时间（Ticks）

        -- 循环读取轨道事件，直到达到轨道末尾或文件末尾
        while file:seek("cur") < track_start_pos + track_size do
            -- 1. 读取 Delta Time (ticks)
            local delta_time = read_vlq(file)
            if delta_time == nil then break end
            
            -- 更新当前轨道的绝对时间
            track_time_ticks = track_time_ticks + delta_time

            -- 2. 读取 Status Byte 或 Running Status
            local status_char = file:read(1)
            if not status_char then break end
            local status_byte = string.byte(status_char)

            local rewind_byte = false

            if status_byte < 0x80 then
                -- Running Status: Status Byte 被省略，当前字节是 Data Byte 1
                rewind_byte = true
            else
                -- 新的 Status Byte
                running_status = status_byte
            end
            
            -- 如果触发 Running Status，我们需要重读 Status Byte 字符作为 Data Byte 1
            if rewind_byte then
                file:seek("cur", -1)
                status_byte = running_status
            end

            -- Note On event (0x90 to 0x9F) 或 Note Off event (0x80 to 0x8F)
            if (status_byte >= 0x80) and (status_byte <= 0x9F) then
                -- Note On/Off: 2 个数据字节 (音高, 力度)
                local data_bytes = file:read(2)
                if data_bytes and #data_bytes == 2 then
                    local pitch = string.byte(data_bytes, 1)
                    local velocity = string.byte(data_bytes, 2)
                    
                    -- !!! 核心改动：检查音高是否在支持的范围内 !!!
                    if pitch >= LOWEST_SUPPORTED_PITCH and pitch <= HIGHEST_SUPPORTED_PITCH then
                        local pitch_id = pitch % 12
                        local octave = math.floor(pitch / 12) - 1 
                        local note_name = NOTE_NAMES_VERBOSE[pitch_id] .. octave
                        
                        -- 计算继电器的偏移量 (1 到 36)
                        local pitch_for_relay_offset = pitch - LOWEST_SUPPORTED_PITCH + 1
                        
                        local event_type = "note_off"
                        if status_byte >= 0x90 and velocity > 0 then
                            event_type = "note_on"
                            notes_in_track = notes_in_track + 1
                        end

                        -- 收集 Note Event
                        table.insert(event_list, {
                            type = event_type,
                            time_ticks = track_time_ticks,
                            pitch = pitch,
                            -- pitch_for_relay_offset 是 1-36 的值，对应继电器 ID 的偏移
                            pitch_for_relay_offset = pitch_for_relay_offset,
                            velocity = velocity,
                            note_name = note_name
                        })
                    else
                        -- 忽略范围外的音高
                        file:read(2)
                        print(string.format("  Skipping note: Pitch %d is outside the supported range (%d-%d).", pitch, LOWEST_SUPPORTED_PITCH, HIGHEST_SUPPORTED_PITCH))
                    end
                end
                
            elseif (status_byte >= 0xA0 and status_byte <= 0xEF) then
                -- Poly Aftertouch, Control Change, Program Change, Channel Aftertouch, Pitch Bend
                
                local channel = status_byte % 16
                if channel == 0xC or channel == 0xD then
                    -- Program Change (0xC), Channel Aftertouch (0xD) - 1 个数据字节
                    file:read(1)
                else
                    -- 剩余大部分消息 - 2 个数据字节
                    file:read(2)
                end

            elseif status_byte == 0xFF then
                -- Meta Event (0xFF)
                local meta_type_char = file:read(1)
                if meta_type_char then
                    local meta_type = string.byte(meta_type_char)
                    local length = read_vlq(file) 
                    
                    if meta_type == 0x51 and length == 3 then
                        -- Set Tempo Event (0xFF 0x51 0x03 [3 bytes MPQN])
                        local mpqn_bytes = file:read(3)
                        local new_mpqn = bytes_to_int(mpqn_bytes)
                        
                        -- 收集 Tempo Change Event
                        table.insert(event_list, {
                            type = "tempo",
                            time_ticks = track_time_ticks,
                            mpqn = new_mpqn
                        })
                        
                    elseif length and length > 0 then
                        -- Skip data bytes for other meta events
                        file:read(length)
                    end

                    -- End of Track 事件：0xFF 0x2F 0x00
                    if meta_type == 0x2F and length == 0 then
                        print("Track End (0xFF 0x2F 0x00)")
                        break
                    end
                end

            -- 忽略 SysEx (0xF0, 0xF7) 和其他系统消息

            end
        end

        print(string.format("Track #%d parsing complete. Found %d Note events.", track_idx, notes_in_track))
        total_notes_found = total_notes_found + notes_in_track
    end

    file:close()
    
    print("\n=======================================")
    print(string.format("Total Note On events found in file: %d", total_notes_found))
    
    -- 3. 按 Ticks 绝对时间排序所有事件
    table.sort(event_list, function(a, b)
        -- 在绝对时间相同时，Note Off 应该先于 Note On 发生，以避免短暂的卡顿
        if a.time_ticks == b.time_ticks then
            if a.type == "note_off" and b.type == "note_on" then return true end
            if a.type == "tempo" then return true end -- Tempo 应该尽可能早地应用
            return false
        end
        return a.time_ticks < b.time_ticks
    end)
    
    return tpqn_division
end


--- 播放已排序的事件
local function playMidi(tpqn_division)
    if #event_list == 0 then
        print("No events to play.")
        return
    end

    -- 播放时的状态变量
    local current_mpqn = event_list[1].mpqn -- 默认从第一个节奏事件开始
    local seconds_per_tick = (current_mpqn / 1000000) / tpqn_division
    
    local current_abs_time_seconds = 0
    local last_event_time_ticks = 0
    
    local all_notes_verbose = {}

    print("--- Starting Synchronized Playback ---")

    for i, event in ipairs(event_list) do
        -- 1. 处理 Tempo Change 事件
        if event.type == "tempo" then
            -- 如果这是第一个事件，或者节奏发生了变化
            -- 我们只在 time_ticks 匹配时才真正更新 tempo，因为 event_list 已经包含 0 ticks 时的默认 tempo
            if event.time_ticks >= last_event_time_ticks and event.mpqn ~= current_mpqn then
                current_mpqn = event.mpqn
                seconds_per_tick = (current_mpqn / 1000000) / tpqn_division
                print(string.format("  [TEMPO] Absolute Time Ticks: %d, New MPQN=%d (BPM=%.2f), New Seconds/Tick=%.6f", 
                                    event.time_ticks, current_mpqn, 60000000 / current_mpqn, seconds_per_tick))
            end
        end
        
        -- 2. 计算并等待时间差
        local delta_ticks = event.time_ticks - last_event_time_ticks
        local delay_seconds = delta_ticks * seconds_per_tick

        if delay_seconds > 0 then
            -- 如果有时间间隔，则等待
            sleep(delay_seconds)
            current_abs_time_seconds = current_abs_time_seconds + delay_seconds
        end

        last_event_time_ticks = event.time_ticks

        -- 3. 处理 Note On/Off 事件
        if event.type == "note_on" or event.type == "note_off" then
            -- 使用完整的偏移量 (1到36) 来计算继电器 ID
            local relay_id = INDEX_START + event.pitch_for_relay_offset
            
            -- 使用 pcall 捕获 peripheral.find 错误，防止程序崩溃
            local ok, relay = pcall(peripheral.find, "redstone_relay", function(name, rs)
                return name == ("redstone_relay_" .. relay_id)
            end)

            if not ok or not relay then
                print(string.format("ERROR: Could not find redstone_relay_%d (Pitch %s). Skipping note.", relay_id, event.note_name))
            else
                local output_state = (event.type == "note_on")
                
                -- 将 Note Event 添加到显示列表
                if event.type == "note_on" then
                    table.insert(all_notes_verbose, event.note_name)
                end
                
                relay.setOutput("front", output_state)
                print(string.format("T=%.4f s | %s: %s (Relay ID: %d)", 
                                    current_abs_time_seconds, 
                                    event.type:upper(), 
                                    event.note_name, 
                                    relay_id))
            end
        end
        
    end

    print("--- Playback Finished ---")
end

-- 1. 执行解析
local tpqn = parseMidi()

-- 2. 执行播放（只有在成功解析并获取 TPQN 后才播放）
if tpqn then
    playMidi(tpqn)
end
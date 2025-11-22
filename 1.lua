local FILENAME = "4.mid"
local INDEX_START = 39

local LOWEST_SUPPORTED_PITCH = 48 -- C3 (MIDI Pitch 48)
local HIGHEST_SUPPORTED_PITCH = 83 -- B5 (MIDI Pitch 83)
local RANGE_SIZE = HIGHEST_SUPPORTED_PITCH - LOWEST_SUPPORTED_PITCH + 1 -- 36

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
        --print("ERROR: Could not open file " .. FILENAME .. ": " .. tostring(err))
        return
    end

    --print("--- Parsing MIDI file: " .. FILENAME .. " ---")
    
    -- 1. 解析 MIDI Header Chunk (MThd)
    local header_id = file:read(4) -- 'MThd'
    local header_size_str = file:read(4) -- 6 (固定长度)
    local format_str = file:read(2)
    local num_tracks_str = file:read(2)
    local division_str = file:read(2)
    
    if header_id ~= "MThd" or not header_size_str then
        --print("ERROR: File is not a valid MIDI file or is too short.")
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
        --print("WARNING: SMPTE time code detected (not TPQN). Tempo calculation may be inaccurate.")
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

    --print(string.format("MIDI Format: %d | Num Tracks: %d | Ticks/QN: %d", format, num_tracks, tpqn_division))
    --print(string.format("Relay Range (36 slots): %d (C3) to %d (B5). Relays %d to %d.", LOWEST_SUPPORTED_PITCH, HIGHEST_SUPPORTED_PITCH, INDEX_START + 1, INDEX_START + RANGE_SIZE))
    --print("---------------------------------------")
    
    -- 2. 解析 MIDI Track Chunks (MTrk)
    local total_notes_found = 0

    for track_idx = 1, num_tracks do
        --print(string.format(">>> Processing Track #%d <<<", track_idx))

        local track_id = file:read(4) -- 'MTrk'
        local track_size_str = file:read(4)

        if track_id ~= "MTrk" or not track_size_str then
            --print("WARNING: Expected MTrk identifier, but file may have ended or format is incorrect.")
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
                --print(string.format("DEBUG: Tick=%d, Status Byte skipped (0x%X). Using Running Status 0x%X.", track_time_ticks, status_byte, running_status))
            else
                -- 新的 Status Byte
                running_status = status_byte
                --print(string.format("DEBUG: Tick=%d, New Status Byte 0x%X", track_time_ticks, status_byte))
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
                
                if not data_bytes or #data_bytes < 2 then
                    --print(string.format("FATAL PARSE ERROR: Expected 2 data bytes for Note Event (Status 0x%X) but got %d bytes. Track sync failed.", status_byte, #data_bytes or 0))
                    break -- Critical failure, stop parsing this track
                end

                local pitch = string.byte(data_bytes, 1)
                local velocity = string.byte(data_bytes, 2)
                
                -- 【调试关键点】记录读取到的原始字节
                --print(string.format("DEBUG: Raw Note: Pitch Byte=0x%X (%d), Velocity Byte=0x%X (%d). Status=0x%X", pitch, pitch, velocity, velocity, status_byte))
                
                -- --- Pitch Mapping Logic ---
                
                -- 1. 原始音高信息 (用于显示，如 D6)
                local pitch_id = pitch % 12
                local octave = math.floor(pitch / 12) - 1 
                local note_name = NOTE_NAMES_VERBOSE[pitch_id] .. octave
                
                -- 2. 计算与 C3 (48) 的相对距离
                local relative_pitch = pitch - LOWEST_SUPPORTED_PITCH
                
                -- 3. 使用数学模运算将相对距离环绕到 0-35 (RANGE_SIZE-1) 范围内。
                -- (a % n + n) % n 确保结果是正数。
                local wrapped_index_0_35 = (relative_pitch % RANGE_SIZE + RANGE_SIZE) % RANGE_SIZE
                
                -- 4. 转换为 1-indexed 的继电器偏移量 (1 到 36)
                local pitch_for_relay_offset = wrapped_index_0_35 + 1
                
                -- 5. 计算映射后的音高信息 (用于显示，如 D3)
                local mapped_midi_pitch = LOWEST_SUPPORTED_PITCH + wrapped_index_0_35
                local mapped_pitch_id = mapped_midi_pitch % 12
                local mapped_octave = math.floor(mapped_midi_pitch / 12) - 1 
                local mapped_note_name = NOTE_NAMES_VERBOSE[mapped_pitch_id] .. mapped_octave
                
                -- -------------------------
                
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
                    pitch_for_relay_offset = pitch_for_relay_offset,
                    velocity = velocity,
                    note_name = note_name,          -- 原始音符名称 (e.g., D6)
                    mapped_note_name = mapped_note_name -- 映射后音符名称 (e.g., D3)
                })
                
            elseif (status_byte >= 0xA0 and status_byte <= 0xEF) then
                -- Poly Aftertouch (0xA), Control Change (0xB), Program Change (0xC), 
                -- Channel Aftertouch (0xD), Pitch Bend (0xE)
                
                local channel_type = math.floor(status_byte / 16) -- A to E
                local data_bytes_to_read = 2 -- 默认为 2 个数据字节
                
                if channel_type == 0xC or channel_type == 0xD then
                    -- Program Change (0xC), Channel Aftertouch (0xD) - 1 个数据字节
                    data_bytes_to_read = 1
                end
                
                file:read(data_bytes_to_read)
                --print(string.format("DEBUG: Channel Message 0x%X detected. Skipping %d data bytes.", status_byte, data_bytes_to_read))

            -- 【重要改进：处理所有系统消息】
            elseif status_byte >= 0xF0 and status_byte <= 0xFF then
                -- SysEx, System Common, and Meta events
                
                -- F0 (SysEx Start) and F7 (SysEx End/Escape) are handled by VLQ length
                if status_byte == 0xF0 or status_byte == 0xF7 then
                    local length = read_vlq(file)
                    --print(string.format("DEBUG: SysEx (0x%X) detected, length VLQ=%d. Skipping data.", status_byte, length or 0))
                    if length and length > 0 then file:read(length) end
                
                -- F1 (Time Code), F3 (Song Select) - 1 data byte
                elseif status_byte == 0xF1 or status_byte == 0xF3 then
                    --print(string.format("DEBUG: System Common (0x%X) detected. Skipping 1 data byte.", status_byte))
                    file:read(1)
                
                -- F2 (Song Position) - 2 data bytes
                elseif status_byte == 0xF2 then
                    --print(string.format("DEBUG: System Common (0x%X) detected. Skipping 2 data bytes.", status_byte))
                    file:read(2)
                
                -- F4, F5 (Undefined) - 0 data bytes, do nothing
                elseif status_byte == 0xF4 or status_byte == 0xF5 then
                    --print(string.format("DEBUG: Undefined System Common (0x%X) detected. Skipping 0 bytes.", status_byte))
                
                -- Real-time messages (F8-FE) - 0 data bytes, handled by the receiver, do nothing
                
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
                            --print(string.format("DEBUG: Meta Tempo (0x%X 0x51) detected. New MPQN: %d.", status_byte, new_mpqn))
                            
                        elseif length and length > 0 then
                            -- Skip data bytes for other meta events
                            file:read(length)
                            --print(string.format("DEBUG: Other Meta Event (0x%X 0x%X) detected. Skipping %d data bytes.", status_byte, meta_type, length))
                        end

                        -- End of Track 事件：0xFF 0x2F 0x00
                        if meta_type == 0x2F and length == 0 then
                            --print("Track End (0xFF 0x2F 0x00)")
                            break
                        end
                    end
                
                else
                    -- 其他系统消息或实时消息 (F8-FE)，没有数据字节需要跳过
                    --print(string.format("DEBUG: Real-Time or other System Message (0x%X). Skipping 0 bytes.", status_byte))
                end

            -- 如果 Status Byte 不是 0x80-0xFF，则文件已损坏或同步严重失败
            else
                 --print(string.format("FATAL PARSE ERROR: Encountered unrecognized byte 0x%X after Delta Time. Track sync failed.", status_byte))
                 break
            end
        end

        --print(string.format("Track #%d parsing complete. Found %d Note events.", track_idx, notes_in_track))
        total_notes_found = total_notes_found + notes_in_track
    end

    file:close()
    
    --print("\n=======================================")
    --print(string.format("Total Note On events found in file: %d", total_notes_found))
    
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
        --print("No events to play.")
        return
    end

    -- 播放时的状态变量
    local current_mpqn = event_list[1].mpqn -- 默认从第一个节奏事件开始
    local seconds_per_tick = (current_mpqn / 1000000) / tpqn_division
    
    local current_abs_time_seconds = 0
    local last_event_time_ticks = 0
    
    local all_notes_verbose = {}

    --print("--- Starting Synchronized Playback ---")

    for i, event in ipairs(event_list) do
        -- 1. 处理 Tempo Change 事件
        if event.type == "tempo" then
            -- 如果这是第一个事件，或者节奏发生了变化
            -- 我们只在 time_ticks 匹配时才真正更新 tempo，因为 event_list 已经包含 0 ticks 时的默认 tempo
            if event.time_ticks >= last_event_time_ticks and event.mpqn ~= current_mpqn then
                current_mpqn = event.mpqn
                seconds_per_tick = (current_mpqn / 1000000) / tpqn_division
                --print(string.format("  [TEMPO] Absolute Time Ticks: %d, New MPQN=%d (BPM=%.2f), New Seconds/Tick=%.6f", event.time_ticks, current_mpqn, 60000000 / current_mpqn, seconds_per_tick))
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
                --print(string.format("ERROR: Could not find redstone_relay_%d (Mapped Pitch %s). Skipping note.", relay_id, event.mapped_note_name))
            else
                local output_state = (event.type == "note_on")
                
                -- 将 Note Event 添加到显示列表
                if event.type == "note_on" then
                    table.insert(all_notes_verbose, event.note_name)
                end
                
                relay.setOutput("front", output_state)
                -- 打印详细的映射信息
                --print(string.format("T=%.4f s | %s: Original %s (MIDI %d) -> Mapped to %s (Offset: %d, Relay ID: %d)", current_abs_time_seconds, event.type:upper(), event.note_name, event.pitch, event.mapped_note_name,event.pitch_for_relay_offset, relay_id))
            end
        end
        
    end

    --print("--- Playback Finished ---")
end

-- 1. 执行解析
local tpqn = parseMidi()

-- 2. 执行播放
if tpqn then
    playMidi(tpqn)
end
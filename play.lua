RELAY_INDEX = 77

function split(str,delimiter)
    local dLen = string.len(delimiter)
    local newDeli = ''
    for i=1,dLen,1 do
        newDeli = newDeli .. "["..string.sub(delimiter,i,i).."]"
    end

    local locaStart,locaEnd = string.find(str,newDeli)
    local arr = {}
    local n = 1
    while locaStart ~= nil
    do
        if locaStart>0 then
            arr[n] = string.sub(str,1,locaStart-1)
            n = n + 1
        end

        str = string.sub(str,locaEnd+1,string.len(str))
        locaStart,locaEnd = string.find(str,newDeli)
    end
    if str ~= nil then
        arr[n] = str
    end
    return arr
end

print("Input file name:")
local fileName = read()

local file, err = io.open(fileName, "r")
    if not file then
        print("ERROR: Could not open file " .. fileName .. ": " .. tostring(err))
        return
    end

    for line in io.lines(fileName) do
        print(line)
        local relay_id = 
        note = split(line, "|")
        
        relay_id = RELAY_INDEX + note[2]

        -- 使用 pcall 捕获 peripheral.find 错误，防止程序崩溃
        local ok, relay = pcall(peripheral.find, "redstone_relay", function(name, rs)
            return name == ("redstone_relay_" .. relay_id)
        end)

        if not ok or not relay then
            print(string.format("ERROR: Could not find redstone_relay_%d (Mapped Pitch %s). Skipping note.", relay_id, event.mapped_note_name))
        else
            local output_state = (note[1] == "on")
                        
            relay.setOutput("front", output_state)
        end
        sleep(note[3])
    end

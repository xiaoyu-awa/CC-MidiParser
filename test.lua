while true do 
    local a = 1
    print("Now:"..tostring(a))
    for i=1,36 do
        local relay = { peripheral.find("redstone_relay",function(name, rs)
                if name==("redstone_relay_"..tostring(i+39)) then
                    return true
                else
                    return false
                end
            end) }
        relay[1].setOutput("front",false)
        relay[1].setOutput("front",true)
        sleep(0.05)
        relay[1].setOutput("front",false)
    end
    a=a+1
    sleep(5)
end
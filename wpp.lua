local debugMode = false
local CURRENT_VERSION = "2"
local THIS_COMPUTER_ID = os.getComputerID()

local currentProtocol = "wpp@default"
local prefetchCache = {}

local function cloneTable(oldTable)
    local newTable = {}
    for k,v in pairs(oldTable) do
        newTable[k] = v
    end
    return newTable
end

local function splitString(inputstr, sep)
    if sep == nil then
        sep = "%s"
    end
    local t={}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        table.insert(t, str)
    end
    return t
end

local function accessKeyPath(theTable, keyPath)
    for k,currentKey in pairs(keyPath) do
        theTable = theTable[currentKey]
    end

    return theTable
end

local function walkTableAndModify(theTableOrValue, handlerFn, keyPath)
    if keyPath == nil then
        keyPath = {}
    end

    if type(theTableOrValue) == "table" then
        theTableOrValue = handlerFn(keyPath, theTableOrValue)
        if type(theTableOrValue) ~= "table" then
            return theTableOrValue
        end

        for k,v in pairs(theTableOrValue) do
            newKeyPath = cloneTable(keyPath)
            table.insert(newKeyPath, k)
            theTableOrValue[k] = walkTableAndModify(v, handlerFn, newKeyPath)
        end
        return theTableOrValue
    else
        return handlerFn(keyPath, theTableOrValue)
    end
end

local function log(message)
    local logMessage = debug.getinfo(2).currentline ..": ".. message

    if debugMode then
        print(logMessage)
        --rednet.broadcast({type="debug", version=CURRENT_VERSION, data=logMessage}, "debug_".. currentProtocol)
    end
end

-- Start->Wireless Modem Setup
peripheral.find("modem", function(name, wrapped)
    if wrapped.isWireless() then
        rednet.open(name)
    end
end)
 
if not rednet.isOpen() then
    error("No wireless modem found", 2)
end
-- End->Wireless Modem Setup

-- Start->
local function parsePeripheralUrl(peripheralUrl)
    local urlParts = splitString(peripheralUrl, "/")

    if urlParts[1] == (currentProtocol ..":") and urlParts[2] and urlParts[3] then
        returnTable = {clientId=tonumber(urlParts[2]), peripheralId=urlParts[3]}

        if urlParts[4] then
            returnTable.methodName = urlParts[4]
            if urlParts[5] then
                returnTable.keyPath = {unpack(urlParts, 5)}
            end
        end

        return returnTable
    else
        return nil
    end
end

local function sendMessage(clientId, type, data)
    log("Sending message with type '".. type .."' to ".. currentProtocol .."://".. clientId .." with data: ".. textutils.serialize(data))
    rednet.send(clientId, {type=type, version=CURRENT_VERSION, data=data}, currentProtocol)
end

local function sendReply(clientId, data)
    sendMessage(clientId, "reply", data)
end

local function recieveReply()
    local clientId, message = rednet.receive(currentProtocol, 10)

    if message == nil then
        return nil
    end

    if(message.type == "reply") then
        return message
    else
        return nil
    end
end
-- End->

local nativePeripheral = peripheral
-- Start->Wrapped Peripheral API funtcions
--      These are ran on the computers that are directly connected to the peripherals
local wrappedPeripheralApi = {
    getNames=function(clientId)
        log("Real getNames(".. clientId ..")")

        sendReply(clientId, nativePeripheral.getNames())
    end,
    isPresent=function(clientId, peripheralName)
        log("Real isPresent("..clientId..", ".. peripheralName ..")")

        sendReply(clientId, nativePeripheral.isPresent(peripheralName))
    end,
    getType=function(clientId, peripheralName)
        log("Real getType("..clientId..", ".. peripheralName ..")")

        sendReply(clientId, nativePeripheral.getType(peripheralName))
    end,
    getMethods=function(clientId, peripheralName)
        log("Real getMethods("..clientId..", ".. peripheralName ..")")

        sendReply(clientId, nativePeripheral.getMethods(peripheralName))
    end,
    call=function(clientId, peripheralName, methodName, ...)
        local args = ...
        log("Real call("..clientId..", ".. peripheralName ..", ".. methodName ..", ".. textutils.serialize(args) ..")")

        local status,result = pcall(
            function()
                local callResult = {nativePeripheral.call(peripheralName, methodName, unpack(args))}

                callResult = walkTableAndModify(callResult, function(keyPath, value)
                    if type(value) == "function" then
                        return {isWppRpcRefrence=true, funcUrl=currentProtocol .. "://" .. clientId .. "/" .. peripheralName, methodName=methodName, methodArguments=args, keyPath=keyPath}
                    end
                    return value
                end)

                return callResult
            end)

        sendReply(clientId, {returned=result, error=not status})
    end,
    callRpcFunction=function(clientId, peripheralName, methodName, methodArguments, keyPath, ...)
        local args = ...
        debug("Real callRpcFunction("..clientId..", ".. peripheralName ..", ".. methodName ..", ".. textutils.serialize(methodArguments) ..", ".. textutils.serialize(keyPath) ..", ".. textutils.serialize(args) ..")")

        local status,result = pcall(
            function()
                local callResult = {nativePeripheral.call(peripheralName, methodName, unpack(methodArguments))}

                nestedCallResult = accessKeyPath(callResult, keyPath)(unpack(args))
                nestedCallResult = walkTableAndModify(nestedCallResult, function(keyPath, value)
                    if type(value) == "function" then
                        return {isWppRpcRefrence=true, funcUrl=currentProtocol .. "://" .. clientId .. "/" .. peripheralName, methodName=methodName, methodArguments=methodArguments, keyPath=keyPath}
                    end
                    return value
                end)

                return nestedCallResult
            end)

        sendReply(clientId, {returned=result, error=not status})
    end,
    wppPrefetch=function(clientId, peripheralName, methods)
        log("Real wppPrefetch("..clientId..", ".. peripheralName ..", ".. textutils.serialize(methods) ..")")
        local methodResults = {}
        
        for possibleMethodName,methodInfo in pairs(methods) do
            local methodName
            local methodArgs

            if type(methodInfo) == "table" then
                methodName = possibleMethodName
                methodArgs = methodInfo
            else
                methodName = methodInfo
                methodArgs = {}
            end

            local status,result = pcall(
            function()
                local r = {nativePeripheral.call(peripheralName, methodName, unpack(methodArgs))}
                return r
            end)
    
            if status then
                methodResults[methodName] = result
            end
        end

        sendReply(clientId, methodResults)
    end,
}
-- End->Wrapped Peripheral API funtcions

local remotePeripheral = {}
local wireless = {}
-- Start->Public API functions.
function wireless.setDebugMode(mode)
    debugMode = mode
end

function wireless.connect(networkId)
    log("Changing protocol from ".. currentProtocol .." to wpp@".. networkId)
    currentProtocol = "wpp@".. networkId
end

function wireless.host(networkId)
    rednet.unhost(currentProtocol)
    wireless.connect(networkId)
    rednet.host(currentProtocol, tostring(THIS_COMPUTER_ID))
end

function wireless.localEventHandler(event)
    -- event: {1="message type", 2="sender client id", 3="message data", 4="protocol"}
    if event[1] == "rednet_message" then
        if event[4] == currentProtocol then
            if event[3].version and event[3].version == CURRENT_VERSION then
                log("Recieved message: ".. textutils.serialize(event[3]))
                if event[3].type == "function" then
                    wrappedPeripheralApi[event[3].data.func](event[2], unpack(event[3].data.args or {}))
                end
            else
                print("Recieved event from an unsupported WPP version ("..event[3].version.."). Only version '".. CURRENT_VERSION .."' is supported.")
            end
        end
    end
end

function wireless.listen(networkId)
    rednet.unhost(currentProtocol)
    wireless.connect(networkId)
    rednet.host(currentProtocol, tostring(THIS_COMPUTER_ID))

    print("Listening for WPP events on ".. currentProtocol)
    print("Hold Control+T to quit")
    while(true) do
        local event = {os.pullEvent()}
        wireless.localEventHandler(event)
    end
end

function wireless.prefetchMethods(peripheralUrl, methods)
    log("New prefetchMethods(".. peripheralUrl ..", ".. textutils.serialize(methods) ..")")
    local parsedPeripheralUrl = parsePeripheralUrl(peripheralUrl)

    if parsedPeripheralUrl == nil then
        prefetchCache[peripheralUrl] = {}
        
        for possibleMethodName,methodInfo in pairs(methods) do
            local methodName
            local methodArgs
            
            if type(methodInfo) == "table" then
                methodName = possibleMethodName
                methodArgs = methodInfo
            else
                methodName = methodInfo
                methodArgs = {}
            end

            local status,result = pcall(
            function()
                local r = {remotePeripheral.call(peripheralUrl, methodName, unpack(methodArgs))}
                return r
            end)

            if status then
                prefetchCache[peripheralUrl][methodName] = result
            end
        end
    else
        sendMessage(parsedPeripheralUrl.clientId, "function", {func="wppPrefetch", args={parsedPeripheralUrl.peripheralId, methods}})

        local reply = recieveReply()

        if reply then
            prefetchCache[peripheralUrl] = reply.data
        end
    end
end

-- Start->New peripheral API using WPP
function remotePeripheral.getNames()
    local allNames = nativePeripheral.getNames()

    local clients = table.pack(rednet.lookup(currentProtocol))
    log("New getNames() found these clients: ".. textutils.serialize(clients))

    for n,clientId in ipairs(clients) do
        if clientId ~= THIS_COMPUTER_ID then
            sendMessage(clientId, "function", {func="getNames"})
            local reply = recieveReply()
            log("New getNames() reply: ".. textutils.serialize(reply))

            if reply then
                for n,name in ipairs(reply.data) do
                    table.insert(allNames, currentProtocol .."://" .. clientId .. "/" .. name)
                end
            end
        end
    end

    return allNames
end

function remotePeripheral.isPresent(peripheralUrl)
    log("New isPresent(".. peripheralUrl ..")")

    local parsedPeripheralUrl = parsePeripheralUrl(peripheralUrl)

    if parsedPeripheralUrl == nil then
        log("New isPresent(".. peripheralUrl ..") using local peripheral")
        return nativePeripheral.isPresent(peripheralUrl)
    else
        sendMessage(parsedPeripheralUrl.clientId, "function", {func="isPresent", args={parsedPeripheralUrl.peripheralId}})
        local reply = recieveReply()
        log("New isPresent(".. peripheralUrl ..") reply: ".. textutils.serialize(reply))

        if reply then
            return reply.data;
        else
            return false
        end
    end
end

function remotePeripheral.getType(peripheralUrl)
    log("New getType(".. peripheralUrl ..")")

    local parsedPeripheralUrl = parsePeripheralUrl(peripheralUrl)

    if parsedPeripheralUrl == nil then
        log("New getType(".. peripheralUrl ..") using local peripheral")
        return nativePeripheral.getType(peripheralUrl)
    else
        sendMessage(parsedPeripheralUrl.clientId, "function", {func="getType", args={parsedPeripheralUrl.peripheralId}})
        local reply = recieveReply()
        log("New getType(".. peripheralUrl ..") reply: ".. textutils.serialize(reply))

        if reply then
            return reply.data;
        else
            return nil
        end
    end
end

function remotePeripheral.getMethods(peripheralUrl)
    log("New getMethods(".. peripheralUrl ..")")

    local parsedPeripheralUrl = parsePeripheralUrl(peripheralUrl)

    if parsedPeripheralUrl == nil then
        log("New getMethods(".. peripheralUrl ..") using local peripheral")
        return nativePeripheral.getMethods(peripheralUrl)
    else
        sendMessage(parsedPeripheralUrl.clientId, "function", {func="getMethods", args={parsedPeripheralUrl.peripheralId}})
        local reply = recieveReply()
        log("New getMethods(".. peripheralUrl ..") reply: ".. textutils.serialize(reply))

        if reply then
            return reply.data;
        else
            return nil
        end
    end
end

function remotePeripheral.call(peripheralUrl, method, ...)
    log("New call(".. peripheralUrl ..", ".. method ..", ".. textutils.serialize({...}) ..")")

    if prefetchCache[peripheralUrl] and prefetchCache[peripheralUrl][method] then
        log("New call(".. peripheralUrl ..", ".. method ..") using prefetched return")
        local returnValue = prefetchCache[peripheralUrl][method]
        prefetchCache[peripheralUrl][method] = nil

        return unpack(returnValue)
    end

    local parsedPeripheralUrl = parsePeripheralUrl(peripheralUrl)

    if parsedPeripheralUrl == nil then
        log("New call(".. peripheralUrl ..", ".. method ..") using local peripheral")
        return nativePeripheral.call(peripheralUrl, method, ...)
    else
        sendMessage(parsedPeripheralUrl.clientId, "function", {func="call", args={parsedPeripheralUrl.peripheralId, method, {...}}})
        local reply = recieveReply()
        log("New call(".. peripheralUrl ..", ".. method ..") reply: ".. textutils.serialize(reply))

        if reply then
            if reply.data.error then
                error(reply.data.returned)
            end

            result = walkTableAndModify(reply.data.returned, function(keyPath, value)
                if type(value) == "table" and value.isWppRpcRefrence then
                    return (function(...)
                        sendMessage(parsedPeripheralUrl.clientId, "function", {func="callRpcFunction", args={parsedPeripheralUrl.peripheralId, method, value.methodArguments, value.keyPath, {...}}})

                        local reply = recieveReply()
                        if reply then
                            if reply.data.error then
                                error(reply.data.returned)
                            end

                            return reply.data.returned
                        else
                            return nil
                        end
                        return 
                    end)
                end

                return value
            end)
            
            return result;
        else
            return nil
        end
    end
end

function remotePeripheral.wrap(peripheralUrl)
    log("New wrap(".. peripheralUrl ..")")

    local parsedPeripheralUrl = parsePeripheralUrl(peripheralUrl)

    if parsedPeripheralUrl == nil then
        log("New wrap(".. peripheralUrl ..") using local peripheral")
        return nativePeripheral.wrap(peripheralUrl)
    else
        if not remotePeripheral.isPresent(peripheralUrl) then
            return nil
        end

        local peripheralMethods = remotePeripheral.getMethods(peripheralUrl)
        log("New wrap(".. peripheralUrl ..") wrapping these methods: ".. textutils.serialize(peripheralMethods))

        local wrappedMethodsTable = {}

        if peripheralMethods then
            for n,method in ipairs(peripheralMethods) do
                wrappedMethodsTable[method] = function(...)
                    return remotePeripheral.call(peripheralUrl, method, ...)
                end
            end
        end

        wrappedMethodsTable["wppPrefetch"] = function(methods)
            wireless.prefetchMethods(peripheralUrl, methods)
        end

        return wrappedMethodsTable;
    end
end

function remotePeripheral.find(type, filterFunction)
    log("New find(".. type ..", hasFilterFunction=".. tostring(not(not filterFunction) or false) ..")")
    local foundToReturn = nativePeripheral.find(type, filterFunction)

    local allPeripherals = remotePeripheral.getNames()

    for n,peripheralUrl in ipairs(allPeripherals) do
        if remotePeripheral.getType(peripheralUrl) == type then
            local wrappedPeripheral = remotePeripheral.wrap(peripheralUrl)

            if filterFunction then
                local peripheralName = remotePeripheral.getName(peripheralUrl)

               if(filterFunction(peripheralName, wrappedPeripheral)) then
                    table.insert(foundToReturn, wrappedPeripheral)
               end
            else
                table.insert(foundToReturn, wrappedPeripheral)
            end
        end
    end

    local next = next
    if next(foundToReturn) == nil then
        return nil
    else
        return foundToReturn
    end
end
-- End->New peripheral API using WPP
-- End->Public API Functions

return {wireless=wireless, peripheral=remotePeripheral}

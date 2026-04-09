csctf.version           = "0.1.9"
csctf.on                = 0
csctf.teamOneStation    = 1299457 --Sedina D14
csctf.teamTwoStation    = 1082369 -- Bractus D9
csctf.shipMaxSpeed      = 0
csctf.hasEnemyFlag      = 0
csctf.enemyFlag         = 0
csctf.enemyFlagId       = 0
csctf.myFlagId          = 0
csctf.myFlagTargetId    = 0
csctf.gameLoopTimer     = Timer()
csctf.myTeam            = 0
csctf.myStation         = 0
csctf.enemyStation      = 0
csctf.reconnectAttempts = 0
csctf.reconnectTimer    = Timer()

function csctf.turbooff() gkinterface.GKProcessCommand('+turbo 0') end

-- Safe send: silently drops messages while disconnected or mid-reconnect
function csctf.send(msg)
	if csctfClient then
		csctfClient:Send(msg)
	end
end

function csctf.output(input)
	local output
	if csctf.on == 0 then
		return
	end
	output = "\12700ffff-=CTF=- " .. input .. "\127o"
	print(output)
end

function csctf.HomeAlert(team)
	if team == 1 then
		csctf.output("Warning: Team 1 home station should be in Sedina, not Bractus. Change your home to Sedina D-14.")
	else
		csctf.output("Warning: Team 2 home station should be in Bractus, not Sedina. Change your home to Bractus D-9.")
	end
end

function csctf.CTFStart()
	csctf.Client_Init()
	csctf.shipMaxSpeed = GetActiveShipMaxSpeed()
	csctf.gameLoopTimer:SetTimeout(25,csctf.GameLoop)
	csctf.on = 1
end

function csctf.CTFStop()
	-- Cancel any pending reconnect attempt before doing anything else
	csctf.reconnectAttempts = 0
	csctf.reconnectTimer:Kill()
	if csctf.hasEnemyFlag == 1 then
		JettisonAll()
		csctf.hasEnemyFlag = 0
		csctf.enemyFlagId  = 0
		csctf.send("ACTION 5 " .. GetPlayerName())	--flag drop
		csctf.output("Flag ejected, do /ctfstop again to stop client functions")
		return
	end
	csctf.shipMaxSpeed   = 0
	csctf.hasEnemyFlag   = 0
	csctf.enemyFlag      = 0
	csctf.enemyFlagId    = 0
	csctf.myFlagId       = 0
	csctf.myFlagTargetId = 0
	csctf.myTeam         = 0
	csctf.myStation      = 0
	csctf.enemyStation   = 0

	csctf.Client_stop()
	csctf.output("You have left CTF. To rejoin use /ctfstart")
	csctf.on = 0
end

function csctf.CTFSay(_,message)
	local output
	if csctf.on == 0 then
		return
	end
	output = "[Team " .. csctf.myTeam .. ":" .. ShortLocationStr(GetCurrentSectorid()) .. " ] <" .. GetPlayerName() .. "> " .. table.concat(message," ")
	csctf.send("ACTION 7 " .. output)
end

function csctf.CTFHelp()
	print("\12700ffffCSCTF is a game in a game, trying to recreate an experience like the VendettaTest CTF in Vendetta Online")
	print("Team 1 home is Sedina D14, Team 1 players go to Bractus D9 and buy a piece of cargo and bring it to Sedina D14")
	print("Team 2 home is Bractus D9, Team 2 players go to Sedina D14 and buy a piece if cargo and bring it to Bractus D9")
	print("Only 1 flag per team is in play at a time, if the flag is dropped you have 3 minutes to recover it before it resets")
	print("Flag carrier loses the ability to turbo when carrying the flag, you must defend the carrier")
	print("/ctfstart to start and join the game")
	print("/ctfstop to stop and disconnect the game")
	print("/ctfsay to talk ONLY to team members")
	print("Keep in mind this is not perfect and workarounds may be possible, please play nice and have fun --CrazySpence\127o")
end

function csctf.GameLoop()
	if csctf.on == 0 then
		return
	end
	if csctf.hasEnemyFlag == 1 then
		if GetActiveShipSpeed() > csctf.shipMaxSpeed then
			csctf.turbooff()
--			if infiniturbo ~= nil then --infini turbo plugin detection
--				infiniturbo.running = false
--			end
		end
	end
	csctf.gameLoopTimer:SetTimeout(25,csctf.GameLoop)
end

function csctf.eventhandler(event,data,data1)
	if csctf.on == 0 then
		return
	end
	local shipInventory
	local stationLocation
	local myChar = GetPlayerName()
	if event == "LEAVING_STATION" then
		csctf.shipMaxSpeed = GetActiveShipMaxSpeed()
		if csctf.enemyFlag == 0 then
			JettisonAll()
		end
	end
	--Detect cargo Grab, Cargo purchases, Cargo Drops
	if event == "INVENTORY_ADD" then
		local itemname = GetInventoryItemName(data)
		if PlayerInStation() == true then
			if GetStationLocation() == csctf.enemyStation then --If no flag is in play and you buy a commodity at enemy station it becomes flag
				if csctf.enemyFlag == 0 then
					if GetInventoryItemClassType(data) == 0 then -- ores and commodity's show as 0, ships 1, addons 2. We want 0
						csctf.enemyFlag    = itemname
						csctf.enemyFlagId  = data
						csctf.hasEnemyFlag = 1
						csctf.send("ACTION 4 " .. csctf.enemyFlag)	--flag Steal
						RequestLaunch()
					end
				end
			end
		else
			if itemname == csctf.enemyFlag then
				csctf.hasEnemyFlag = 1
				csctf.enemyFlagId  = data
				csctf.send("ACTION 4 " .. csctf.enemyFlag)	--flag Steal
			else
				--Drop it, you're playing CTF not trading!
				--Also since I'm using cargo as a flag this is a small countermeasure against cheating.
				JettisonAll()
			end
		end
	end
	if event == "INVENTORY_REMOVE" then
		if data == csctf.enemyFlagId then
			csctf.hasEnemyFlag = 0
			csctf.enemyFlagId  = 0
			csctf.send("ACTION 5 " .. myChar)	--flag drop
		end
	end

	--If you die and have the flag kill the hasEnemyFlag variable
	if event == "PLAYER_DIED" then
		if data == GetCharacterID() then
			if csctf.hasEnemyFlag == 1 then
				csctf.hasEnemyFlag = 0
				csctf.enemyFlagId  = 0
				csctf.send("ACTION 3 " .. myChar)	--flag drop on death
			end
			if data1 ~= data then --not a suicide
				csctf.send("ACTION 2 " .. GetPlayerName(data) .. ":" .. GetPlayerName(data1)) --pk record
			end
		end
	end

	if event == "ENTERED_STATION" then
		if csctf.hasEnemyFlag == 1 then
			if GetStationLocation() == csctf.myStation then
				csctf.send("ACTION 6 " .. myChar .. ":" .. csctf.enemyFlag)	--flag Cap
				--reset variables
				csctf.hasEnemyFlag = 0
				csctf.enemyFlagId  = 0
				csctf.enemyFlag    = 0
			else
				RequestLaunch() --Stop trying to make stop overs you lazy carrier
			end
		end
	end

	if event == "PLAYER_ENTERED_SECTOR" then
		if data == GetCharacterID() then
			csctf.send("ACTION 1 " .. ShortLocationStr(GetCurrentSectorid()))
		end
		if csctf.enemyFlag == 0 then
			JettisonAll()
		end
	end
	if event == "PLAYER_HOME_CHANGED" then -- Alert user of proper game ethics.
		if csctf.myTeam == "1" then
			if(SystemNames[GetSystemID(GetHomeStation())]) == "Bractus" then
				csctf.HomeAlert(1)
			end
		end
		if csctf.myTeam == "2" then
			if(SystemNames[GetSystemID(GetHomeStation())]) == "Sedina" then
				csctf.HomeAlert(2)
			end
		end
	end
end

-- Called by reconnectTimer to make the next connection attempt
function csctf.DoReconnect()
	if csctf.on == 0 then
		csctf.reconnectAttempts = 0
		return
	end
	csctf.output("Attempting reconnect " .. csctf.reconnectAttempts .. " of 3...")
	csctf.Client_Init()
end

function csctf.Disconnected()
	if csctfClient then
		csctfClient = nil
	end
	if csctf.on == 1 then
		csctf.reconnectAttempts = csctf.reconnectAttempts + 1
		if csctf.reconnectAttempts <= 3 then
			csctf.output("Connection lost. Reconnect attempt " .. csctf.reconnectAttempts .. " of 3 in 30 seconds...")
			csctf.reconnectTimer:SetTimeout(30000, csctf.DoReconnect)
		else
			csctf.output("Could not reconnect after 3 attempts, stopping CTF")
			csctf.reconnectAttempts = 0
			csctf.CTFStop()
		end
	end
end

function csctf.Connected(conn,success)
	if conn then
		csctf.reconnectAttempts = 0  -- successful connection, clear retry counter
		csctf.output("Connecting to CTF server...")
		conn:Send("VERSION " .. csctf.version)
		conn:Send("REGISTER " .. GetPlayerName())
	else
		csctf.output("Connection failed")
		csctfClient = nil
		csctf.Disconnected()  -- counts as an attempt; schedules next retry or gives up
	end
end

function csctf.Incoming(conn,line)
	if line == "PING" then
		csctf.send("PONG")
	elseif string.sub(line,1,7) == "GLOBAL " then
		csctf.output(string.sub(line,8))
	elseif string.sub(line,1,8) == "SETTEAM " then
		csctf.myTeam = string.sub(line,9)
		if(csctf.myTeam == "1") then
			csctf.myStation    = csctf.teamOneStation
			csctf.enemyStation = csctf.teamTwoStation
			if(SystemNames[GetSystemID(GetHomeStation())]) == "Bractus" then
				csctf.HomeAlert(1)
			end
		else
			csctf.myStation    = csctf.teamTwoStation
			csctf.enemyStation = csctf.teamOneStation
			if(SystemNames[GetSystemID(GetHomeStation())]) == "Sedina" then
				csctf.HomeAlert(2)
			end
		end
		csctf.output("Assigned to team " .. csctf.myTeam)
		csctf.send("ACTION 1 " .. ShortLocationStr(GetCurrentSectorid())) --Initialize location with server state
	elseif string.sub(line,1,9) == "FLAGITEM " then
		if string.sub(line,10) == "" then
			csctf.enemyFlag = 0
		else
			csctf.enemyFlag = string.sub(line,10)
		end
	elseif string.sub(line,1,14) == "VERIFYCARRIER " then
		-- Server is asking us to confirm we still have the flag after a restart/reconnect
		local item = string.sub(line,15)
		if csctf.hasEnemyFlag == 1 and csctf.enemyFlag == item then
			csctf.send("ACTION 8 1")
			csctf.output("Confirmed still carrying " .. item .. " after reconnect")
		else
			csctf.send("ACTION 8 0")
			csctf.hasEnemyFlag = 0
			csctf.enemyFlagId  = 0
			csctf.enemyFlag    = 0
		end
	elseif line == "RESETFLAG" then
		csctf.hasEnemyFlag = 0
		csctf.enemyFlagId  = 0
		csctf.enemyFlag    = 0
		JettisonAll()
	else
		csctf.output(line)
	end
end

RegisterEvent(csctf.eventhandler, "LEAVING_STATION")
RegisterEvent(csctf.eventhandler, "INVENTORY_ADD")
RegisterEvent(csctf.eventhandler, "INVENTORY_REMOVE")
RegisterEvent(csctf.eventhandler, "PLAYER_DIED")
RegisterEvent(csctf.eventhandler, "ENTERED_STATION")
RegisterEvent(csctf.eventhandler, "PLAYER_ENTERED_SECTOR")
RegisterEvent(csctf.eventhandler, "PLAYER_HOME_CHANGED")

RegisterUserCommand("ctfstart",csctf.CTFStart)
RegisterUserCommand("ctfstop",csctf.CTFStop)
RegisterUserCommand("ctfsay",csctf.CTFSay)
RegisterUserCommand("ctfhelp",csctf.CTFHelp)

--Exit handlers
RegisterEvent(csctf.CTFStop,"UNLOAD_INTERFACE")
RegisterEvent(csctf.CTFStop,"PLAYER_LOGGED_OUT")

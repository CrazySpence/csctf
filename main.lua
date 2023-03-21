--CrazySpence CTF 0.1.7
--Testing plausibility of making a CTF game with lua

csctf = {}

csctf.version        = "0.1.7"
csctf.on             = 0
csctf.teamOneStation = 1299457 --Sedina D14
csctf.teamTwoStation = 1082369 -- Bractus D9
csctf.shipMaxSpeed   = 0
csctf.hasEnemyFlag   = 0
csctf.enemyFlag      = 0
csctf.enemyFlagId    = 0
csctf.myFlagId       = 0
csctf.myFlagTargetId = 0
csctf.gameLoopTimer  = Timer()
csctf.myTeam         = 0
csctf.myStation      = 0
csctf.enemyStation   = 0

function csctf.turbooff() gkinterface.GKProcessCommand('+turbo 0') end

function csctf.output(input) 
	local output
	if csctf.on == 0 then
		return
	end
	output = "\12700ffff-=CTF=- " .. input .. "\127o"
	print(output)
end
	
function csctf.CTFStart()
	csctf.Client_Init()
	csctf.shipMaxSpeed = GetActiveShipMaxSpeed()
	csctf.gameLoopTimer:SetTimeout(25,csctf.GameLoop)
	csctf.on = 1
end

function csctf.CTFStop()
	if csctf.hasEnemyFlag == 1 then
		JettisonAll()
		csctf.hasEnemyFlag = 0
		csctf.enemyFlagId  = 0
		csctfClient:Send("ACTION 5 " .. GetPlayerName())	--flag drop		
		csctf.output("Flag ejected, do /ctfstop again to stop client functions")
		return	
	end
	csctf.on             = 0
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

end

function csctf.CTFSay(_,message)
	local output
	if csctf.on == 0 then
		return
	end
	output = "[Team " .. csctf.myTeam .. ":" .. ShortLocationStr(GetCurrentSectorid()) .. " ] <" .. GetPlayerName() .. "> " .. table.concat(message," ")
	csctfClient:Send("ACTION 7 " .. output)
end

function csctf.CTFHelp()
    print("\12700ffffCSCTF is a game in a game, trying to recreate an experience like the VendettaTest CTF in Vendetta Online")
	print"Team 1 home is Sedina D14, Team 1 players go to Bractus D9 and buy a piece of cargo and bring it to Sedina D14"
	print("Team 2 home is Bractus D9, Team 2 players go to Sedina D14 and buy a piece if cargo and bring it to Bractus D9")
	print("Only 1 flag per team is in play at a time, if the flagg is dropped you have 3 minutes to recover it before it resets")
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
	--Detect cargo Grab,Cargo purchases, Cargo Drops
    if event == "INVENTORY_ADD" then 
		local itemname = GetInventoryItemName(data)
		if PlayerInStation() == true then
			if GetStationLocation() == csctf.enemyStation then --If no flag is in play and you buy a commodity at enemy station it becomes flag
				if csctf.enemyFlag == 0 then
					if GetInventoryItemClassType(data) == 0 then -- ores and commodity's show as 0, ships 1, addons 2. We want 0
						csctf.enemyFlag    = itemname
						csctf.enemyFlagId  = data
            			csctf.hasEnemyFlag = 1
						csctfClient:Send("ACTION 4 " .. csctf.enemyFlag)	--flag Steal
						RequestLaunch()
					end	
				end
			end
		else
			if itemname == csctf.enemyFlag then
				csctf.hasEnemyFlag = 1
				csctf.enemyFlagId  = data
				csctfClient:Send("ACTION 4 " .. csctf.enemyFlag)	--flag Steal
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
			csctfClient:Send("ACTION 5 " .. myChar)	--flag drop	
		end
	end
	
	--If you die and have the flag kill the hasEnemyFlag variable
	if event == "PLAYER_DIED" then
		if data == GetCharacterID() then
			if csctf.hasEnemyFlag == 1 then
				csctf.hasEnemyFlag = 0
				csctf.enemyFlagId  = 0
				csctfClient:Send("ACTION 3 " .. myChar)	--flag drop		
			end
		end
		if data == GetCharacterID() then
			if(data1 == data) then
				return --Suicide, TODO: when stats are eventually recorded this must notify server of suicide
			end
			csctfClient:Send("ACTION 2 " .. GetPlayerName(data) .. ":" .. GetPlayerName(data1)) --pk record
		end
	end
	
	if event == "ENTERED_STATION" then
		if csctf.hasEnemyFlag == 1 then
			if GetStationLocation() == csctf.myStation then
				csctfClient:Send("ACTION 6 " .. myChar .. ":" .. csctf.enemyFlag)	--flag Cap
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
           csctfClient:Send("ACTION 1 " .. ShortLocationStr(GetCurrentSectorid()))
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

--TCP stuff
local TCP = dofile("tcpsock.lua")

csctfClient = nil

function csctf.Connected(conn,success)
   if conn then
	   csctf.output("Connecting to CTF server...")
	   conn:Send("VERSION " .. csctf.version)
	   conn:Send("REGISTER " .. GetPlayerName())
   else
	   csctf.output("Connection Failed")
	   csctfClient = nil
   end
end

function csctf.Disconnected()
   csctf.output("Connection to CTF server interrupted")
   if csctfClient then
      csctfClient = nil
   end
   if csctf.on == 1 then
	   csctf.on = 0
   end	   
end

function csctf.HomeAlert(team)
	if team == 1 then
		csctf.output("Team One members should home in Odia or Sedina. Homing in Bractus gives an unfair advantage")
	end
	if team == 2 then
		csctf.output("Team Two members should home in Odia or Bractus. Homing in Sedina gives an unfair advantage")
	end
end

function csctf.Incoming(conn,line)
  	if line == "PING" then 
    	csctfClient:Send("PONG")
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
	    csctfClient:Send("ACTION 1 " .. ShortLocationStr(GetCurrentSectorid())) --Initialize location with server state
	elseif string.sub(line,1,9) == "FLAGITEM " then
		if string.sub(line,10) == "" then
			csctf.enemyFlag = 0
		else	
			csctf.enemyFlag = string.sub(line,10)
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

function csctf.Client_Init()
   if not csctfClient then
      csctfClient = TCP.make_client("philtopia.com", "10500", csctf.Connected, csctf.Incoming, csctf.Disconnected)
   else 
      csctf.output("CTF Client is already active")
   end
end

function csctf.Client_stop()
   if csctfClient then
      csctfClient:Send("LOGOUT\n")
   end
end

--Exit handlers
RegisterEvent(csctf.CTFStop,"UNLOAD_INTERFACE")
RegisterEvent(csctf.CTFStop,"PLAYER_LOGGED_OUT")

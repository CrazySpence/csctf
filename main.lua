--CrazySpence CTF 0.2.0 remote download
csctf = {}

--------------------
--TCP and HTTP stuff
local HTTP,json,b64 = dofile("httplib/httplib.lua")
local TCP = dofile("tcpsock.lua") -- the one in httplib wasnt working, I or someone mustve changed something and forgot
csctf.server = "http://voupr.spenced.com/csctf/0.2.0/current.lua" -- Current running game version goes here (for now)
csctfClient = nil
ctffile = ""

-----------------------------
--Download current game stuff
local function getsystemnote(index)
	return "settings/"..GetPlayerName().."/system"..index.."notes.txt"
end

function csctf.download() --download the current game logic
	local downloaded = HTTP.new()
	downloaded.method = "GET"
	downloaded.urlopen(csctf.server, function(r)
		if r.body then
			ctffile = r.body.get()
			SaveSystemNotes(ctffile, 290981)  -- update cache for future fallback
			csctf.dostring(ctffile)           -- execute directly from memory (avoids SaveSystemNotes async timing issue)
		else
			console_print("csctf: failed to download update (HTTP " .. tostring(r.status) .. "), using cached version")
			csctf.dofile(getsystemnote(290981))
		end
	end)
end

function csctf.dofile(filename) --stolen from anyx and modified
	local file, fileerr = loadfile(filename)
	if not file then
		print("\127ff0000Error attempting to load "..filename.."\127o")
		console_print("csctf error in "..filename..": "..tostring(fileerr))
		return
	end
	for i=1, 10 do
		-- check for undeclared variables and declare them as needed
		-- only iterates up to 10 times in case it gets stuck in a loop
		local fileinfo = {pcall(file)}
		local ok = table.remove(fileinfo, 1)
		if not ok then
			local err = fileinfo[1]
			local var = err:match("attempt to %a+ %a+ undeclared variable (.+)$")
			console_print(err)
			if var then
				declare(var)
			else
				print("\127ff0000Error attempting to load "..filename.."\127o")
				console_print("csctf error in "..filename..": "..err)
				break
			end
		elseif fileinfo[1] then
			-- pass any return values along
			return unpack(fileinfo)
		else
			return
		end
	end
end

function csctf.dostring(str) --execute lua source directly from a downloaded string
	local loadstr = loadstring or load
	local chunk, err = loadstr(str, "current.lua")
	if not chunk then
		print("\127ff0000Error parsing downloaded current.lua\127o")
		console_print("csctf download parse error: " .. tostring(err))
		return
	end
	for i=1, 10 do
		-- check for undeclared variables and declare them as needed
		local fileinfo = {pcall(chunk)}
		local ok = table.remove(fileinfo, 1)
		if not ok then
			local err = fileinfo[1]
			local var = err:match("attempt to %a+ %a+ undeclared variable (.+)$")
			console_print(err)
			if var then
				declare(var)
			else
				print("\127ff0000Error executing downloaded current.lua\127o")
				console_print("csctf error: " .. err)
				break
			end
		elseif fileinfo[1] then
			return unpack(fileinfo)
		else
			return
		end
	end
end

-------------------------------------
--Game client to server communication

function csctf.Disconnected()
   csctf.output("Connection to CTF server interrupted")
   if csctfClient then
      csctfClient = nil
   end
   if csctf.on == 1 then
	   csctf.on = 0
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

RegisterEvent(csctf.download,"PLAYER_ENTERED_GAME") -- download fresh version on login

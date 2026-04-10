-- $Id: httplib.lua 32 2007-12-29 00:52:11Z firsm $
--
-- Copyright (c) 2007 Fabian "firsm" Hirschmann <fhirschmann@gmail.com>

-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:

-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.

-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
-- Documentation is available at: http://code.fahi.eu/trac/wiki/docs/httplib
--
-- TODO:
--  Make the lib actually care about cookie_attribs
--  Timeout
--  HTTP/1.1 cookie handling

local TCP = dofile("httplib/tcpsock.lua")
local json_encode = dofile("httplib/json_encode.lua")
local json_decode = dofile("httplib/json_decode.lua")
local json = {encode=json_encode.encode, decode=json_decode.decode}
local b64 = dofile("httplib/b64.lua")

local _ -- My trash can
local HTTP = {}
HTTP.__version = "$Revision: 32 $"
HTTP.__version = tonumber(string.match(HTTP.__version, "%$Revision: (%d*) %$"))
local cookie_attribs = {
    'version',
    'expires',
    'max-age',
    'domain',
    'path',
    'port',
    'comment',
    'commenturl',
    'secure',
    'discard'
}

local function unescape (s)
    local s = string.gsub(s, "+", " ")
    s = string.gsub(s, "%%(%x%x)", function (h)
        return string.char(tonumber(h, 16))
    end)
    return s
end

local function escape (s)
    local s = string.gsub(s, "([&=+%c])", function (c)
        return string.format("%%%02X", string.byte(c))
    end)
    s = string.gsub(s, " ", "+")
    return s
end

local function encode (t)
    local s = ""
    for k,v in pairs(t) do
        s = s .. "&" .. escape(k) .. "=" .. escape(v)
    end
    return string.sub(s, 2)     -- remove first `&'
end

local function decode (s)
    local cgi = {}
    for name, value in string.gfind(s, "([^&=]+)=([^&=]+)") do
        name = unescape(name)
        value = unescape(value)
        cgi[name] = value
    end
    return cgi
end


-- I miss python...
local function list_iter (t)
    local i = 0
    local n = table.getn(t)
    return function ()
        i = i+1
        if i <= n then return t[i] end
    end
end

local function list_hasval(t, v)
    for x in list_iter(t) do
        if x == v then
            return true
        end
    end
    return false
end


-- stolen from some website
local function split(str, pat, noiter)
    local t = {}  -- NOTE: use {n = 0} in Lua-5.0
    local fpat = "(.-)" .. pat
    local last_end = 1
    local s, e, cap = str:find(fpat, 1)
    while s do
        if s ~= 1 or cap ~= "" then
            table.insert(t,cap)
        end
        last_end = e+1
        s, e, cap = str:find(fpat, last_end)
    end
    if last_end <= #str then
        cap = str:sub(last_end)
        table.insert(t, cap)
    end
    if noiter then
        return t
    end
    return list_iter(t)
end

local filters = {}
function filters.beautify(page)
    -- Put HTML tags in lowercase (but leaves attribute names untouched)
    return page:gsub("<[^%s>]+", string.lower)
end

function filters.striphtml(page)
    return page:gsub('<%/?[%w="_ ]+>', '')
end

function filters.grep(page, arg)
    local tbl = {}
    for line in page:gmatch("[^\r\n]+") do
        if string.match(line, arg) then
            table.insert(tbl, line)
        end
    end
    
    return table.concat(tbl, '\n')
end

local function GetCookies(dom)
    local cookies_for_dom = {}
    local i = 0
    local stop = false
    while not stop do
        i = i+1
        local y = dom..'_'..tostring(i)
        local c = gkini.ReadString('httplib cookies', y, '-')
        if c == '-' then
            stop = true
        else
            table.insert(cookies_for_dom, c)
            cookies_for_dom[i] = json.decode(c)
        end
    end
    return cookies_for_dom
end

local function MakeCookieHeaderLines(cookies)
    local lines = {}
    local attribs = {}
    local used = {}
    for cookie in list_iter(cookies) do
        for attrib in list_iter(cookie) do
            local prefix = ''
            if list_hasval(cookie_attribs, attrib[1]) then
                -- all key attribues need to be prefixed with $
                prefix = '$'
                -- make the first letter uppercase (cosmetic?!)
                --attrib[1] = attrib[1]:gsub("%a", string.upper, 1)
            end
            if not list_hasval(used, attrib[1]) then
                table.insert(attribs, prefix..attrib[1]..'='..attrib[2])
                table.insert(used, attrib[1])
            end
        end
    end
    table.insert(lines, {'Cookie', table.concat(attribs, '; ')..';'})
    return lines
end

local function WriteCookies(cookies)
    local dom, i
    if table.getn(cookies) == 0 then return false end

    -- so let's figure out the domain the cookie should be sent to
    -- we assume that all cookies came from the same server, so the domain
    -- value should be equal in all of them
    -- if it's even "allowed" to send multiple Set-Cookie: lines...
    for x in list_iter(cookies[1]) do
        if x[1] == "domain" then
            dom = x[2]
        end
    end
    
    -- now we need to know the name of the attribute which the cookie wants to
    -- set (and of course we don't want key attributes), so we can delete existing
    -- cookies with the same attribute name
    local new_cookies_attrib_names = {}
    for cookie in list_iter(cookies) do
        for attribs in list_iter(cookie) do
            if not list_hasval(cookie_attribs, attribs[1]) then
                table.insert(new_cookies_attrib_names, attribs[1])
            end
        end
    end

    -- Now let's get all the cookies we have for our domain
    local existing_cookies = GetCookies(dom)
    
    -- If the cookies we just received overwrite existing cookies, we discard
    -- the existing cookies now
    i = 0
    for cookie in list_iter(existing_cookies) do
        i = i+1
        for attribs in list_iter(cookie) do
            if not list_hasval(cookie_attribs, attribs[1]) then
                if not list_hasval(new_cookies_attrib_names, attribs[1]) then
                    -- we want to keep this existing cookie, so we just append
                    -- it to the list of cookies we've got from the most recent
                    -- server response
                    table.insert(cookies, cookie)
                end
            end
        end
    end
    
    -- now we "delete" all the existing cookies for that domain
    -- all cookies get overwritten with every request in most cases
    -- anyway.
    local l = 1+table.getn(existing_cookies)
    i = 0
    while i < l do
        i = i+1
        local y = dom..'_'..tostring(i)
        gkini.WriteString('httplib cookies', y, '-')
    end
    
    -- now we are ready to finally store our new (and old) cookies!
    i = 0
    for cookie in list_iter(cookies) do
        i = i+1
        local y = dom..'_'..tostring(i)
        gkini.WriteString('httplib cookies', y, json.encode(cookie))
    end
end


function HTTP.new ()
    local http = {}
    http.__disable_cookies = false
    http.headers = {}
    http.headers.__headers = { -- Please don't add your own headers here - use headers.set()
        {'Accept', 'text/xml,application/xhtml+xml,text/html;q=0.9,text/plain;q=0.8,*/*;q=0.5'},
        {'Accept-Language', 'en-us,en;q=0.5'},
        {'Accept-Charset', 'ASCII;q=0.7'},
        {'User-Agent', 'httplib for Vendetta Online - http://code.fahi.eu'},
        {'Connection', 'close'},
    }
    http.POST = {}
    http.POST.__data = {}
    http.GET = {}
    http.GET.__data = {}
    http.AUTH = {}
    http.AUTH.__AUTH = {}
    http.AUTH.__AUTH["username"] = false
    http.AUTH.__AUTH["password"] = false
    http.method = "GET"
    http.version = "1.0"
    http.timeout = 10 -- timeout in seconds
    http.__links_followed = 0
    http.__max_links_follow = 10
    
    -- #### header functions
    function http.headers.all() return list_iter(http.headers.__headers) end
    function http.headers.set(name, value)
        -- set a specific http header
        local i = 0
        local present = false
        for _, v in pairs(http.headers.__headers) do
            i = i+1
            if v[1] == name then
                http.headers.__headers[i][2] = value
                present = true
            end
        end
        if not present then
            table.insert(http.headers.__headers, {name, value})
        end
    end
    
    -- ### HTTP Authenticate functions
    function http.AUTH.add(username, password)
        http.AUTH.__AUTH["username"] = username
        http.AUTH.__AUTH["password"] = password
    end
    function http.AUTH.clear()
        http.AUTH.__AUTH["username"] = false
        http.AUTH.__AUTH["password"] = false
    end
    
    
    -- #### HTTP GET/POST data functions
    function http.POST.add(name, value) table.insert(http.POST.__data, {name, value}) end
    function http.POST.all() return list_iter(http.POST.__data) end
    function http.POST.clear() http.POST = {} end
    
    function http.GET.add(name, value) table.insert(http.GET.__data, {name, value}) end
    function http.GET.all() return list_iter(http.GET.__data) end
    function http.GET.clear() http.GET = {} end
    
    function http.urlopen(u, cb)
        local content = {}
        local buff = {}
        local response = {}
        response.url = {}
        buff.body = {}
        buff.header = {}
        local bytes_received = 0
            -- yeah, this is cheating, I'm not exactly sure where these
            -- 5 bytes get stripped of, but I guess it's the \r\n before the
            -- body, but then I'm still missing 3 bytes
        local waitfor = 0
        local in_body = false
        local condition = false
        local timed_out = false
        local timer = Timer()
        timer:SetTimeout(http.timeout*1000,
            function ()
                timed_out = true
                if http.sock then
                    -- dunno why, but this isn't working (thread issue?)
                    -- http.sock:Disconnect()
                end
            end
        )
        
                
        if not (string.match(u, "http://(.-)/(.*)$")) then u = u..'/' end
        response.url.host, response.url.path = string.match(u, "http://(.-)/(.*)$") -- Thanks to Miharu
        if string.match(response.url.host, ':') then
            response.url.host, response.url.port = string.match(response.url.host, "(.*):(.*)$")
        else
            response.url.port = 80
        end
        
        -- TODO: escaping the get data when specified in the URL
        
        -- Handling GET data
        if table.getn(http.GET.__data) > 0 then
            local gdata = {}
            for d in http.GET.all() do
                -- mmh, not sure why I'm not just using the table index here
                local var = d[1]
                local val = d[2]
                gdata[var] = val
            end
            gdata = encode(gdata)
            response.url.path = response.url.path..'?'..gdata
        end
        
        -- Cookies!
        if not http.__disable_cookies then
            local send_cookies = GetCookies(response.url.host)
            if table.getn(send_cookies) > 0 then
                send_cookies = MakeCookieHeaderLines(send_cookies)
                for send_cookie in list_iter(send_cookies) do
                    table.insert(http.headers.__headers, send_cookie)
                end
            end
        end
        
        -- HTTP Auth
        if http.AUTH.__AUTH["username"] and http.AUTH.__AUTH["password"] then
            -- http://www.ietf.org/rfc/rfc2617.txt
            -- To receive authorization, the client sends the userid and password,
            --  separated by a single colon (":") character, within a base64
            --  encoded string in the credentials.
            local h = http.AUTH.__AUTH["username"]..':'..http.AUTH.__AUTH["password"]
            
            -- if you happen to find a pure lua implementation of md5, let me know
            -- I'd love to implement digest auth
            http.headers.set('Authorization', 'Basic '..b64.encode(h))
        end
        
        
        table.insert(content, http.method..' /'..response.url.path..' HTTP/'..http.version)
        table.insert(content, 'Host: '..response.url.host..':'..tostring(response.url.port))
        for _, v in pairs(http.headers.__headers) do
            table.insert(content, v[1]..': '..v[2])
        end
        
        local function makeerrorresponse(code, msg)
            local response = {}
            response.status = code
            response.statusmsg = msg
            
            return response
        end
        
        local function callcb(status, response)
            if cb then cb(status, response) end
        end
        
        if http.method == "POST" then
            if table.getn(http.POST.__data) == 0 then
                return callcb(makeerrorresponse(0, "No data to post"))
            end
            table.insert(content, 'Content-Type: application/x-www-form-urlencoded')
            
            -- Handling POST data
            local pdata = {}
            for d in http.POST.all() do
                local var = d[1]
                local val = d[2]
                pdata[var] = val
            end
            pdata = encode(pdata)
            table.insert(content, 'Content-Length: '..string.len(pdata))
            table.insert(content, '')
            table.insert(content, pdata)
        else                                
            table.insert(content, '')
        end
        table.insert(content, '')
        local function make() return table.concat(content, '\r\n') end
        local function ConnectionMade(conn, success)
            if not conn then return callcb(makeerrorresponse(501, "Bad Gateway")) end
            conn:Send(make())
        end
        
        local function MakeHeader()
            response.headers = {}
            response.headers.__headers = {}
            response.cookies = {}
            response.cookies.__cookies = {}
            local header = table.concat(buff.header)
            
            for line in header:gmatch("[^\r\n]+") do
                if string.match(line, "^HTTP") then
                    response.status, response.statusmsg = string.match(line, "^HTTP/1.%d (%d%d%d) ?(.*)")
                    response.status = tonumber(response.status)
                elseif string.match(line, "^Set%-Cookie: ") then
                    -- http://tools.ietf.org/html/rfc2109
                    -- TODO: http://tools.ietf.org/html/rfc2965
                    local cookie = string.match(line, "Set%-Cookie: (.*)")

                    local attribs = {}
                    local known_attribs = {}
                    -- I had that conversation recently:
                    -- me: nothing
                    -- litespeed: Set-Cookie: session=xxx; expires=Wed, 04-Jun-2008 17:09:06 GMT; domain=vendetta-online.com; path=/;
                    -- me: Cookie: session=xxx; $Expires=Wed, 04-Jun-2008 17:09:06 GMT; $Domain=vendetta-online.com; $Path=/; $Version=1;
                    -- litespeed: Set-Cookie: session=xxx;+$Expires; expires=Wed, 04-Jun-2008 17:09:07 GMT; domain=vendetta-online.com; path=/;
                    --
                    -- wtf is the +$Expires for?!
                    -- I couldn't find any reference to it in the RFCs, so maybe that's just litespeed doing weird stuff?
                    -- The only thing I can think of:
                    --  a) it wants to cookie to expire after this session
                    --  b) it wants to tell me that the only attribute that has changed is the $expires attribute
                    -- I think b) is most likely, and I'll just remove that info from the cookie since
                    -- I'm going to update the cookie anyway no matter if it has changed or not
                      
                    -- let's do it the easy way...
                    cookie = string.gsub(cookie, '%+%$%w+;', '')
                      
                    for attrib in split(cookie..' ', "; ") do
                        local name, value = string.match(attrib, '(.*)=(.*)')
                        table.insert(attribs, {name, value})
                        table.insert(known_attribs, string.lower(name))
                    end
                    
                    -- complement missing attributes
                    local default_attribs = {
                        {'domain', response.url.host},
                        -- {'path', response.url.path}, -- RFC says no
                        {'version', '1'}
                        
                    }
                    for x in list_iter(default_attribs) do
                        if not list_hasval(known_attribs, x[1]) then
                            table.insert(attribs, {x[1], x[2]})
                        end
                    end
                    
                    table.insert(response.cookies.__cookies, attribs)
                    
                end
                local name, value = string.match(line, "(.*): (.*)")
                if name then
                    table.insert(response.headers.__headers, {name, value})
                end
            end
            
            -- Header functions
            function response.headers.all() return list_iter(response.headers.__headers) end
            function response.headers.get(name)
                for header in response.headers.all() do
                    if header[1] == name then
                        return header[2]
                    end
                end
            end
            
            -- Conditions
            if response.headers.get("Transfer-Encoding") == "chunked" then
                -- The chunked encoding modifies the body of a message in order to
                -- transfer it as a series of chunks, each with its own size indicator.
                condition = "chunked"
            elseif tonumber(response.headers.get("Content-Length")) > -1 then
                -- classic!
                condition = "length_known"
                waitfor = tonumber(response.headers.get("Content-Length"))
            end
            
        end
        
        local function MakeResponse()
            response.body = {}
            response.body.__body = table.concat(buff.body, '\n')
            
            -- add all the filters.* functions
            for x, y in pairs(filters) do
                response.body[x] = function(arg)
                    response.body.__body = y(response.body.__body, arg)
                end
            end
            
            function response.body.get()
                return response.body.__body
            end
            
            return response
        end
        
        local last_line = nil
        local last_line_of_chunk = nil
        local function LineReceived(conn, line)
            -- We are still receiving data, so we reset the timer
            timer:SetTimeout(http.timeout*1000)
            
            local data = table.concat(buff.header)
            if line == '\r' and not in_body then
                -- the server has finished sending the header
                -- note that tcpsock.lua already does some sort of buffering,
                -- so we only need to put together the response line by line
                in_body = true
                -- now let's get the interesting stuff out of the header
                MakeHeader()
                
                --if not http.__disable_cookies then -- wtf, doesn't work
                    WriteCookies(response.cookies.__cookies)
                --end
            end
            if in_body then
                bytes_received = bytes_received+string.len(line..'\n')
                if condition == "chunked" then
                    -- http://www.freesoft.org/CIE/RFC/2068/233.htm
                    --if last_line == "\r" and tonumber('0x'..line) then
                    --for some reason I don't get \r from some servers
                    waitfor = waitfor - string.len(line..'\n')
                    if tonumber('0x'..line) and waitfor < 0 then
                        last_line_of_chunk = last_line
                        waitfor = tonumber('0x'..line)
                    else
                        if waitfor > 0 then
                            if last_line_of_chunk then
                                table.insert(buff.body, last_line_of_chunk:sub(1,-2)..line)
                                last_line_of_chunk = nil
                            else
                                table.insert(buff.body, line)
                            end
                        else
                            -- we got it all, thanks
                            if http.sock then
                                http.sock:Disconnect()
                            end
                        end
                    end
                elseif condition == "length_known" then
                    table.insert(buff.body, line)
                    if bytes_received >= waitfor then
                        -- we got it all, thanks
                        if http.sock then
                            http.sock:Disconnect()
                        end
                    end
                else
                    table.insert(buff.body, line)
                end
            else
                table.insert(buff.header, line)
            end
            last_line = line
        end
        
        local function ConnectionLost()
            if timer:IsActive() then timer:Kill() end
            if timed_out then
                callcb(makeerrorresponse(0, "Connection timed out"))
            else
                local resp = MakeResponse()
                if list_hasval({301, 302, 303, 307}, resp.status) then
                    http.__links_followed = http.__links_followed+1
                    if http.__links_followed > http.__max_links_follow then
                        callcb(makeerrorresponse(0, "Followed too many locations."))
                    else
                        http.urlopen(response.headers.get('Location'), function(x) callcb(x) end)
                    end
                else
                    callcb(resp)
                end
            end
            http.sock = nil
        end
        http.sock = TCP.make_client(response.url.host, tonumber(response.url.port), ConnectionMade, LineReceived, ConnectionLost)
    end
    
    function http.clear()
        http = nil
    end
    
    return http
end
-- log_print('Http Library Revision '..HTTP.__version..' (c) 2007 Fabian "firsm" Hirschmann <fhirschmann@gmail.com> http://code.fahi.eu/')

return HTTP, json, b64

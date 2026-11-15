-- Minimal test harness for Lua 5.1 under lupa.
local H = { results = {} }

H.ROOT = ROOT

function H.read(path)
    local f = assert(io.open(H.ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

---Loads an addon file the way the client does: as a chunk called with (addonName, ns), optionally in env.
function H.load(name, ns, env)
    local chunk, err = loadstring(H.read("AuctionJudge/" .. name), "@" .. name)
    if not chunk then error(err, 0) end
    if env then setfenv(chunk, env) end
    chunk("AuctionJudge", ns)
end

function H.test(name, fn)
    local ok, err = pcall(fn)
    H.results[#H.results + 1] = { name = name, ok = ok, err = (not ok) and tostring(err) or nil }
end

function H.eq(actual, expected, what)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
    end
end

function H.near(actual, expected, what)
    if type(actual) ~= "number" or math.abs(actual - expected) > 1e-9 then
        error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
    end
end

function H.ok(v, what)
    if not v then error((what or "condition") .. " failed", 2) end
end

return H

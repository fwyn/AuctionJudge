-- Item search queue for random suffix groups (a browse row whose auctions vary in stats): their exact
-- links only come from an item search for the group's key. One query at a time, only while the
-- client's throttle allows it, spaced out, held off while the user is searching, capped per browse
-- search, cheapest group first. Pure: Core sends the queries and reports back. Unit-tested.
local ADDON, ns = ...

local Q = {}
ns.Queue = Q

Q.SPACING = 0.5 -- seconds at least between two queries
Q.HOLD = 1.5    -- seconds of quiet after any browse results event (the user is searching)
Q.TIMEOUT = 5   -- seconds a query may go without results before it counts as failed

local huge = math.huge

function Q.New()
    return { items = {}, sent = 0, failures = 0, inflight = nil, lastSentAt = -huge, holdUntil = -huge }
end

---Queues a group once. group.query: { state = queued | sent | resolved | failed | timeout, attempts,
---results, reason, sentAt }.
function Q.Enqueue(q, group)
    if group.query then return false end
    group.query = { state = "queued", attempts = 0 }
    q.items[#q.items + 1] = group
    return true
end

---Groups still waiting to be sent.
function Q.Length(q)
    local n = 0
    for _, g in ipairs(q.items) do if g.query and g.query.state == "queued" then n = n + 1 end end
    return n
end

---True while there is something to wait for: a query in flight, or queued groups under the cap.
function Q.Waiting(q, cap)
    return q.inflight ~= nil or (q.sent < cap and Q.Length(q) > 0)
end

---Browse results arrived: no queries for a moment.
function Q.Hold(q, now)
    local t = now + Q.HOLD
    if t > q.holdUntil then q.holdUntil = t end
end

---A new browse search replaced the results, or the auction house closed: groups not done are forgotten
---(they can be queued again), the query in flight is dropped and the per-search count starts again.
function Q.Cancel(q)
    for _, g in ipairs(q.items) do
        local s = g.query and g.query.state
        if s == "queued" or s == "sent" then g.query = nil end
    end
    q.items, q.inflight, q.sent = {}, nil, 0
end

---A query in flight for TIMEOUT seconds counts as failed. Returns that group, or nil.
function Q.CheckTimeout(q, now)
    local g = q.inflight
    if g and now - g.query.sentAt >= Q.TIMEOUT then
        g.query.state, g.query.reason = "timeout", "no results within " .. Q.TIMEOUT .. " s"
        q.inflight = nil
        q.failures = q.failures + 1
        return g
    end
    return nil
end

---The next group to search for, or nil and why not: inflight, hold, spacing, empty, cap, throttle.
function Q.Next(q, now, ready, cap)
    if q.inflight then return nil, "inflight" end
    if now < q.holdUntil then return nil, "hold" end
    if now - q.lastSentAt < Q.SPACING then return nil, "spacing" end
    local best
    for _, g in ipairs(q.items) do
        if g.query and g.query.state == "queued" and (not best or (g.price or huge) < (best.price or huge)) then
            best = g
        end
    end
    if not best then return nil, "empty" end
    if q.sent >= cap then return nil, "cap" end
    if not ready then return nil, "throttle" end
    return best
end

function Q.Sent(q, g, now)
    g.query.state, g.query.sentAt = "sent", now
    g.query.attempts = (g.query.attempts or 0) + 1
    q.inflight, q.lastSentAt, q.sent = g, now, q.sent + 1
end

function Q.SendFailed(q, g, reason)
    g.query.state, g.query.reason = "failed", reason
    q.failures = q.failures + 1
    if q.inflight == g then q.inflight = nil end
end

function Q.Resolved(q, g, results)
    g.query.state, g.query.results = "resolved", results
    if q.inflight == g then q.inflight = nil end
end

-- Unit tests of the item search queue (Queue.lua).
local H = ...
local test, eq, ok = H.test, H.eq, H.ok

local ns = {}
H.load("Queue.lua", ns)
local Q = ns.Queue

local function group(key, price) return { key = key, price = price } end

-- A queue with groups a (500), b (100), c (300), at time 0, no hold.
local function setup()
    local q = Q.New()
    local a, b, c = group("a", 500), group("b", 100), group("c", 300)
    Q.Enqueue(q, a)
    Q.Enqueue(q, b)
    Q.Enqueue(q, c)
    return q, a, b, c
end

test("cheapest first, one at a time, spaced", function()
    local q, a, b, c = setup()
    eq(Q.Length(q), 3, "queued")
    eq(Q.Enqueue(q, a), false, "queued once")
    local g = Q.Next(q, 0, true, 60)
    ok(g == b, "cheapest first")
    Q.Sent(q, g, 0)
    eq(b.query.state .. " " .. b.query.attempts, "sent 1", "sent")
    local none, why = Q.Next(q, 0.1, true, 60)
    eq(tostring(none) .. " " .. why, "nil inflight", "one at a time")
    Q.Resolved(q, b, 12)
    eq(b.query.state .. " " .. b.query.results, "resolved 12", "resolved")
    none, why = Q.Next(q, 0.4, true, 60)
    eq(why, "spacing", "at least 0.5 s apart")
    ok(Q.Next(q, 0.5, true, 60) == c, "next cheapest after the spacing")
end)

test("throttle not ready: nothing sent", function()
    local q, _, b = setup()
    local none, why = Q.Next(q, 10, false, 60)
    eq(tostring(none) .. " " .. why, "nil throttle", "waits for the throttle")
    ok(Q.Next(q, 10, true, 60) == b, "then sends")
end)

test("hold off after browse results", function()
    local q = setup()
    Q.Hold(q, 10)
    local _, why = Q.Next(q, 11.4, true, 60)
    eq(why, "hold", "held for 1.5 s")
    Q.Hold(q, 11) -- a later event extends the hold
    _, why = Q.Next(q, 12.4, true, 60)
    eq(why, "hold", "extended")
    ok(Q.Next(q, 12.5, true, 60), "free after the hold")
end)

test("cap per search; a cancel starts the count again and frees unfinished groups", function()
    local q, a, b, c = setup()
    Q.Sent(q, Q.Next(q, 0, true, 2), 0)
    Q.Resolved(q, b, 1)
    Q.Sent(q, Q.Next(q, 1, true, 2), 1)
    Q.Resolved(q, c, 1)
    local none, why = Q.Next(q, 2, true, 2)
    eq(tostring(none) .. " " .. why, "nil cap", "capped")
    eq(Q.Waiting(q, 2), false, "nothing to wait for under the cap")
    eq(Q.Waiting(q, 3), true, "a higher cap: waiting")
    Q.Cancel(q)
    eq(a.query, nil, "unfinished group freed")
    eq(b.query.state, "resolved", "done groups keep their state")
    eq(q.sent .. " " .. Q.Length(q), "0 0", "count and queue reset")
    Q.Enqueue(q, a)
    ok(Q.Next(q, 3, true, 2) == a, "queued again after the cancel")
end)

test("a cancel drops the query in flight", function()
    local q, _, b = setup()
    Q.Sent(q, Q.Next(q, 0, true, 60), 0)
    Q.Cancel(q)
    eq(q.inflight, nil, "nothing in flight")
    eq(b.query, nil, "the sent group can be queued again")
end)

test("stop (exact off) keeps the per-search counts; cancel (new search) resets them", function()
    local q, a, b = setup()
    Q.Sent(q, Q.Next(q, 0, true, 2), 0)
    Q.CheckTimeout(q, 5)
    Q.Sent(q, Q.Next(q, 6, true, 2), 6)
    Q.Stop(q)
    eq(q.inflight, nil, "the query in flight dropped")
    eq(q.sent .. " " .. q.failures, "2 1", "stop: sent and failed still count for this search")
    eq(b.query.state .. " " .. tostring(a.query), "timeout nil", "the failure is kept, the dropped group freed")
    Q.Enqueue(q, a)
    local none, why = Q.Next(q, 7, true, 2)
    eq(tostring(none) .. " " .. why, "nil cap", "on again: no fresh allowance")
    Q.Cancel(q)
    eq(q.sent .. " " .. q.failures, "0 0", "a new search starts both again")
end)

test("timeout after 5 s; send failures counted", function()
    local q, a, b = setup()
    Q.Sent(q, Q.Next(q, 0, true, 60), 0)
    eq(Q.CheckTimeout(q, 4.9), nil, "not yet")
    ok(Q.CheckTimeout(q, 5) == b, "timed out")
    eq(b.query.state .. " / " .. b.query.reason, "timeout / no results within 5 s", "state and reason")
    eq(q.failures, 1, "counted")
    local g = Q.Next(q, 5.5, true, 60)
    Q.SendFailed(q, g, "SendSearchQuery missing")
    eq(g.query.state .. " " .. q.failures, "failed 2", "send failure")
    ok(a.query.state == "queued", "the rest stays queued")
end)

return H

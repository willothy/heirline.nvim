local eq = assert.equals

local r = require("heirline.reactive")

describe("reactive signal", function()
    it("reads and writes a value", function()
        local get, set = r.signal(1)
        eq(1, get())
        set(2)
        eq(2, get())
    end)

    it("returns the committed value from the setter", function()
        local get, set = r.signal("a")
        eq("b", set("b"))
        eq("b", get())
    end)
end)

describe("reactive memo", function()
    it("derives from signals and caches", function()
        local get, set = r.signal(2)
        local runs = 0
        local double = r.memo(function()
            runs = runs + 1
            return get() * 2
        end)

        eq(4, double())
        eq(4, double()) -- cached, no recompute
        eq(1, runs)

        set(5)
        eq(10, double())
        eq(2, runs)
    end)

    it("is lazy: does not run until read", function()
        local get, set = r.signal(1)
        local runs = 0
        local m = r.memo(function()
            runs = runs + 1
            return get()
        end)
        eq(0, runs) -- never read yet
        set(2) -- still not read
        eq(0, runs)
        eq(2, m())
        eq(1, runs)
    end)

    it("does not recompute when an upstream change is a no-op (cutoff)", function()
        local get, set = r.signal(4)
        local even = r.memo(function()
            return get() % 2 == 0
        end)
        local downstream_runs = 0
        local label = r.memo(function()
            downstream_runs = downstream_runs + 1
            return even() and "even" or "odd"
        end)

        eq("even", label())
        eq(1, downstream_runs)

        set(6) -- still even: `even` recomputes to the same value, `label` must not re-run
        eq("even", label())
        eq(1, downstream_runs)

        set(7) -- now odd: `label` must re-run
        eq("odd", label())
        eq(2, downstream_runs)
    end)
end)

describe("reactive effect", function()
    it("runs immediately and on dependency change", function()
        local get, set = r.signal(1)
        local seen = {}
        r.effect(function()
            seen[#seen + 1] = get()
        end)
        eq(1, #seen)
        eq(1, seen[1])
        set(2)
        eq(2, #seen)
        eq(2, seen[2])
    end)

    it("does not re-run when an unread signal changes", function()
        local a_get, a_set = r.signal(1)
        local _, b_set = r.signal(10)
        local runs = 0
        r.effect(function()
            runs = runs + 1
            return a_get()
        end)
        eq(1, runs)
        b_set(20) -- not a dependency
        eq(1, runs)
        a_set(2)
        eq(2, runs)
    end)

    it("tracks dependencies dynamically", function()
        local cond_get, cond_set = r.signal(true)
        local a_get, a_set = r.signal("a")
        local b_get, b_set = r.signal("b")
        local seen = {}
        r.effect(function()
            if cond_get() then
                seen[#seen + 1] = a_get()
            else
                seen[#seen + 1] = b_get()
            end
        end)
        eq("a", seen[#seen])

        -- while cond is true, b is not a dependency
        b_set("b2")
        eq(1, #seen)

        a_set("a2")
        eq("a2", seen[#seen])

        -- switch branches; now b is a dependency and a is not
        cond_set(false)
        eq("b2", seen[#seen])
        local n = #seen
        a_set("a3")
        eq(n, #seen)
        b_set("b3")
        eq("b3", seen[#seen])
    end)
end)

describe("reactive batch", function()
    it("coalesces effect runs", function()
        local a_get, a_set = r.signal(1)
        local b_get, b_set = r.signal(1)
        local runs = 0
        r.effect(function()
            runs = runs + 1
            return a_get() + b_get()
        end)
        eq(1, runs)
        r.batch(function()
            a_set(2)
            b_set(3)
        end)
        eq(2, runs) -- a single re-run for both writes
    end)
end)

describe("reactive cleanup", function()
    it("runs cleanups before re-run and on dispose", function()
        local get, set = r.signal(1)
        local cleanups = 0
        local dispose = r.effect(function()
            get()
            r.on_cleanup(function()
                cleanups = cleanups + 1
            end)
        end)
        eq(0, cleanups)
        set(2) -- cleanup from first run fires before second run
        eq(1, cleanups)
        dispose() -- cleanup from second run fires on disposal
        eq(2, cleanups)
        set(3) -- disposed: no further runs or cleanups
        eq(2, cleanups)
    end)
end)

describe("reactive untrack", function()
    it("reads without subscribing", function()
        local a_get, a_set = r.signal(1)
        local b_get, b_set = r.signal(1)
        local runs = 0
        r.effect(function()
            runs = runs + 1
            a_get()
            r.untrack(function()
                return b_get()
            end)
        end)
        eq(1, runs)
        b_set(2) -- read untracked: no re-run
        eq(1, runs)
        a_set(2)
        eq(2, runs)
    end)
end)

describe("reactive root", function()
    it("disposes owned effects", function()
        local get, set = r.signal(1)
        local runs = 0
        local captured_dispose
        r.root(function(dispose)
            captured_dispose = dispose
            r.effect(function()
                runs = runs + 1
                get()
            end)
        end)
        eq(1, runs)
        set(2)
        eq(2, runs)
        captured_dispose()
        set(3) -- effect disposed with the root
        eq(2, runs)
    end)

    it("runs cleanups registered directly on the root scope on dispose", function()
        local cleaned = 0
        local captured_dispose
        r.root(function(dispose)
            captured_dispose = dispose
            -- Registered against the root owner, not a computation.
            r.on_cleanup(function()
                cleaned = cleaned + 1
            end)
        end)
        eq(0, cleaned)
        captured_dispose()
        eq(1, cleaned)
    end)
end)

describe("reactive equality policy", function()
    it("notifies on every write when equals is false", function()
        local get, set = r.signal({ 1 }, { equals = false })
        local runs = 0
        r.effect(function()
            runs = runs + 1
            get()
        end)
        eq(1, runs)
        set({ 1 }) -- different table, and equals=false forces notify
        eq(2, runs)
    end)

    it("suppresses no-op writes by default", function()
        local get, set = r.signal(5)
        local runs = 0
        r.effect(function()
            runs = runs + 1
            get()
        end)
        eq(1, runs)
        set(5) -- equal: no notify
        eq(1, runs)
        set(6) -- changed: notify
        eq(2, runs)
    end)
end)

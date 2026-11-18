require("hs.ipc")
hs.autoLaunch(true)

hs.hotkey.bind({ "cmd", "shift" }, "k", function()
    hs.application.launchOrFocus("kitty")
end)

local browserBundleID = "com.ardia.browser"
local sessionPath = os.getenv("HOME") .. "/Library/Application Support/" .. browserBundleID .. "/session.json"
local types = hs.eventtap.event.types
local buttonProperty = hs.eventtap.event.properties.mouseEventButtonNumber
local directions = { [3] = -1, [4] = 1 }
local swallowed = {}

local function overSidebar(event)
    local app = hs.application.frontmostApplication()
    if not app or app:bundleID() ~= browserBundleID then return false end
    local window = app:focusedWindow()
    if not window then return false end

    local frame, point = window:frame(), event:location()
    if point.x < frame.x or point.x > frame.x + frame.w
        or point.y < frame.y or point.y > frame.y + frame.h then return false end

    -- Session state is an internal format; pass clicks through if it cannot be read.
    local ok, session = pcall(hs.json.read, sessionPath)
    if not ok or type(session) ~= "table" or type(session.windows) ~= "table" then return false end
    local focused
    for _, candidate in ipairs(session.windows) do
        if candidate.id == session.focusedWindowId then focused = candidate; break end
    end
    if not focused or not focused.sidebarOpen or (focused.tabLayout or "sidebar") ~= "sidebar" then return false end

    local settings = session.settings or {}
    local width = (tonumber(settings.sidebarWidth) or 190) + 8
    if focused.kind ~= "small" and settings.sidebarSide == "right" then return point.x >= frame.x + frame.w - width end
    return point.x <= frame.x + width
end

-- Keep the tap reachable so Lua's garbage collector does not stop it.
sidebarButtons = hs.eventtap.new({ types.otherMouseDown, types.otherMouseUp }, function(event)
    local button = event:getProperty(buttonProperty)
    if not directions[button] then return false end
    if event:getType() == types.otherMouseUp then
        if swallowed[button] then
            swallowed[button] = nil
            return true
        end
        return false
    end
    if not overSidebar(event) then return false end
    swallowed[button] = true
    -- The profile pager ignores horizontal scroll amounts of one or less.
    local scroll = hs.eventtap.event.newScrollEvent({ directions[button] * 2, 0 }, {}, "line")
    scroll:location(event:location())
    return true, { scroll }
end)

hs.accessibilityStateCallback = function()
    if hs.accessibilityState() then
        sidebarButtons:start()
    else
        sidebarButtons:stop()
        swallowed = {}
    end
end
hs.accessibilityStateCallback()

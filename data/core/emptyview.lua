local core = require "core"
local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"

---@class core.emptyview : core.view
---@field super core.view
local EmptyView = View:extend()

function EmptyView:__tostring() return "EmptyView" end

function EmptyView:get_name()
  return "Get Started"
end

function EmptyView:get_filename()
  return ""
end

EmptyView.commands = {
  { fmt = "%s to show all commands", cmd = "core:find-command" },
  { fmt = "%s to go to a file", cmd = "core:find-file" },
  { fmt = "%s to find in files", cmd = "project-search:find" },
  { fmt = "%s to toggle the terminal", cmd = "terminal:toggle" },
  { fmt = "%s to open a folder", cmd = "core:open-project-folder" },
}

-- Rasterize the wordmark runs to an alpha mask at `height` px (box filter),
-- returned as horizontal spans {x, y, w, alpha}. Cached per size.
local logo_cache = {}
local function logo_spans(height)
  height = math.floor(height)
  if logo_cache[height] then return logo_cache[height] end
  local logo = require "core.trexlogo"
  local s = height / logo.height
  local W = math.ceil(logo.width * s)
  local cov = {}
  local runs = logo.runs
  for i = 1, #runs, 3 do
    local x1, y, x2 = runs[i] * s, math.floor(runs[i + 1] * s), (runs[i] + runs[i + 2]) * s
    for tx = math.floor(x1), math.min(W - 1, math.ceil(x2) - 1) do
      local overlap = math.min(x2, tx + 1) - math.max(x1, tx)
      if overlap > 0 then local k = y * W + tx; cov[k] = (cov[k] or 0) + overlap * s end
    end
  end
  local spans = {}
  for y = 0, height - 1 do
    local x = 0
    while x < W do
      local a = math.floor(math.min(1, cov[y * W + x] or 0) * 15 + 0.5)
      local start = x
      while x + 1 < W and math.floor(math.min(1, cov[y * W + x + 1] or 0) * 15 + 0.5) == a do x = x + 1 end
      if a > 0 then spans[#spans + 1] = {start, y, x - start + 1, a / 15} end
      x = x + 1
    end
  end
  logo_cache[height] = {spans = spans, w = W, h = height}
  return logo_cache[height]
end

function EmptyView:draw()
  self:draw_background(style.background)
  -- x,y center-point
  local x = self.position.x + self.size.x / 2
  local y = self.position.y + self.size.y / 2
  local divider_w = math.ceil(1 * SCALE)
  local cmds_x = x + math.ceil(divider_w /2) + style.padding.x
  local logo_right_side = x - math.ceil(divider_w/2) - style.padding.x

  local displayed_cmds = {}
  for _, command in ipairs(self.commands) do
    local keybinding = keymap.get_binding(command.cmd)
     if keybinding ~= nil then
      table.insert(displayed_cmds,{
        fmt = command.fmt,
        keybinding = keybinding
      })
     end
  end
  local cmd_h = style.font:get_height() + style.padding.y
  local cmds_y = y - ((cmd_h * #displayed_cmds)/2)
  for i, cmd in ipairs(displayed_cmds) do
    local cmd_text = string.format(cmd.fmt, cmd.keybinding)
    renderer.draw_text(style.font, cmd_text, cmds_x, cmds_y + cmd_h*(i-1), style.dim)
  end

  local version = VERSION
  local logo = logo_spans(46 * SCALE)
  local logo_h = logo.h
  local logo_y = y - logo_h - style.padding.y / 2
  local logo_x = logo_right_side - logo.w
  local c = style.text
  for _, span in ipairs(logo.spans) do
    renderer.draw_rect(logo_x + span[1], logo_y + span[2], span[3], 1, {c[1], c[2], c[3], (c[4] or 255) * span[4]})
  end
  local vers_x = logo_right_side - style.font:get_width(version)
  local vers_y = y + style.padding.y / 2
  renderer.draw_text(style.font, version, vers_x, vers_y, style.dim)

  local divider_y =  math.min(cmds_y, logo_y) - style.padding.y
  local divider_h = (y - divider_y)*2
  renderer.draw_rect(x - divider_w/2, divider_y, divider_w, divider_h, style.dim)
end

return EmptyView

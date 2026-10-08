-- mod-version:4
-- Saves each edited file once typing pauses. Untitled buffers are left alone.
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local Doc = require "core.doc"

config.plugins.autosave = common.merge({enabled = true, delay = 1}, config.plugins.autosave)

local pending = setmetatable({}, {__mode = "k"})

local on_text_change = Doc.on_text_change
function Doc:on_text_change(...)
  pending[self] = system.get_time()
  return on_text_change(self, ...)
end

local on_close = Doc.on_close
function Doc:on_close(...)
  pending[self] = nil
  return on_close(self, ...)
end

core.add_thread(function()
  while true do
    local options, now = config.plugins.autosave, system.get_time()
    for doc, at in pairs(pending) do
      if now - at >= options.delay then
        pending[doc] = nil
        if options.enabled and doc.abs_filename and doc:is_dirty() then
          local ok, err = pcall(doc.save, doc)
          if not ok then core.error("Autosave failed for %s: %s", doc.filename, err) end
        end
      end
    end
    coroutine.yield(0.25)
  end
end)

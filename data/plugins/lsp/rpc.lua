-- JSON-RPC over a language server's stdio. `parser` and `frame` are pure;
-- `start` runs the process in a thread so the UI never blocks.
local json = require "plugins.lsp.json"
local M = {timeout = 10}

-- Feeds raw stdout chunks; returns the message bodies completed so far.
function M.parser()
  local buf = ""
  return function(chunk)
    buf = buf .. chunk
    local bodies = {}
    while true do
      local hs, he = buf:find("\r\n\r\n", 1, true)
      if not hs then break end
      local len = tonumber(buf:sub(1, hs - 1):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
      if not len then buf = buf:sub(he + 1) -- junk header: drop it, resync on the next one
      elseif #buf - he < len then break
      else bodies[#bodies + 1] = buf:sub(he + 1, he + len); buf = buf:sub(he + len + 1) end
    end
    return bodies
  end
end

function M.frame(msg)
  local body = json.encode(msg)
  return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

return M

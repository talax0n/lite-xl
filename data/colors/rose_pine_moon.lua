local style = require "core.style"
local common = require "core.common"

-- Rosé Pine Moon: https://rosepinetheme.com/palette
style.background = { common.color "#232136" }  -- base
style.background2 = { common.color "#232136" } -- base (sidebars, activity bar)
style.background3 = { common.color "#2a273f" } -- surface (command view)
style.text = { common.color "#908caa" }        -- subtle
style.caret = { common.color "#ea9a97" }       -- rose
style.accent = { common.color "#e0def4" }      -- text
style.dim = { common.color "#6e6a86" }         -- muted
style.divider = { common.color "#393552" }     -- overlay
style.selection = { common.color "#44415a" }   -- highlight med
style.line_number = { common.color "#6e6a86" }
style.line_number2 = { common.color "#e0def4" }
style.line_highlight = { common.color "#2a283e" } -- highlight low
style.scrollbar = { common.color "#393552" }
style.scrollbar2 = { common.color "#56526e" }  -- highlight high
style.scrollbar_track = { common.color "#232136" }
style.nagbar = { common.color "#eb6f92" }
style.nagbar_text = { common.color "#232136" }
style.nagbar_dim = { common.color "rgba(0, 0, 0, 0.45)" }
style.drag_overlay = { common.color "rgba(224,222,244,0.1)" }
style.drag_overlay_tab = { common.color "#ea9a97" }
style.good = { common.color "#9ccfd8" }        -- foam
style.warn = { common.color "#f6c177" }        -- gold
style.error = { common.color "#eb6f92" }       -- love
style.modified = { common.color "#c4a7e7" }    -- iris

style.syntax["normal"] = { common.color "#e0def4" }
style.syntax["symbol"] = { common.color "#e0def4" }
style.syntax["comment"] = { common.color "#6e6a86" }
style.syntax["keyword"] = { common.color "#3e8fb0" }  -- pine
style.syntax["keyword2"] = { common.color "#9ccfd8" } -- foam
style.syntax["number"] = { common.color "#f6c177" }
style.syntax["literal"] = { common.color "#ea9a97" }
style.syntax["string"] = { common.color "#f6c177" }
style.syntax["operator"] = { common.color "#908caa" }
style.syntax["function"] = { common.color "#ea9a97" }

style.log["INFO"]  = { icon = "i", color = style.text }
style.log["WARN"]  = { icon = "!", color = style.warn }
style.log["ERROR"] = { icon = "!", color = style.error }

return style

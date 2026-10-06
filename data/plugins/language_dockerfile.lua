-- mod-version:4
local syntax = require "core.syntax"

syntax.add {
  name = "Dockerfile",
  files = { PATHSEP .. "[Dd]ockerfile[^" .. PATHSEP .. "]*$", "%.dockerfile$", PATHSEP .. "Containerfile$" },
  comment = "#",
  patterns = {
    { pattern = "#.*",                    type = "comment"  },
    { pattern = { '"', '"', '\\' },       type = "string"   },
    { pattern = { "'", "'", '\\' },       type = "string"   },
    { pattern = "%$%{[^}]*%}",            type = "keyword2" },
    { pattern = "%$[%w_]+",               type = "keyword2" },
    { pattern = "^%s*%u+%f[%s]",          type = "keyword"  },
    { pattern = "%-%-[%w%-]+",            type = "function" },
    { pattern = "%d+",                    type = "number"   },
    { pattern = "[%w_%-%.]+",             type = "normal"   },
  },
  symbols = {},
}

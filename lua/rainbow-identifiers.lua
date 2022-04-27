local queries = require "nvim-treesitter.query"

local M = {}

function M.init()
  require "nvim-treesitter".define_modules {
    rainbow_identifiers = {
      module_path = "rainbow-identifiers.internal",
      is_supported = function(lang)
        return queries.get_query(lang, 'locals') ~= nil
      end
    }
  }
end

return M

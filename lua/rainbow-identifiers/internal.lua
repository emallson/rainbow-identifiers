local ts_utils = require('nvim-treesitter.ts_utils')
local queries = require('nvim-treesitter.query')
local parsers = require('nvim-treesitter.parsers')
local nsid = vim.api.nvim_create_namespace("rainbow_identifiers")
-- this is a vendored copy of mpeterv/sha1 at commit 9b462c7
local sha = require('rainbow-identifiers.sha1')
local configs = require('nvim-treesitter.configs')

local M = {}

local hashes = {}
-- define a highlight rule for a hash + color pair
--
-- the hash must be a valid vim identifier (no spaces, no special characters)
local function defhl(hash, color)
  if hashes[hash] == nil then
    hashes[hash] = color
    vim.cmd("highlight default rainbowident" .. hash .. " guifg=" .. color)
  end
end

-- produce a single number representing the hash of `name`
local function hash_text(name, cfg) 
  if name == nil then
    return nil
  end

  local bytes = sha.binary(name)
  local result = 0
  for i=#bytes - cfg.hash_bytes, #bytes do
    local byte = string.byte(bytes, i)
    result = result * 256 + byte
  end

  return result
end


-- methods to convert from CIE L*a*b to XYZ and from XYZ to sRGB.
-- the L*a*b methods are shamelessly taken from emacs' color.el, while the XYZ->sRGB is from easyrgb.com
local cie_epsilon = 216 / 24389
local cie_kappa = 24389 / 27

local function cielab_xyz_rescale(var)
  if math.pow(var, 3) > cie_epsilon then
    return math.pow(var, 3)
  else
    return (var * 116 - 16) / cie_kappa
  end
end

-- D65 white point in CIE XYZ. taken from emacs color.el
local cielab_ref = { 0.950455, 1.0, 1.088753 }

local function cielab_to_xyz(l, a, b)
  local ref_x, ref_y, ref_z = unpack(cielab_ref)
  local fy = (l + 16) / 116
  local fz = fy - b / 200
  local fx = (a / 500) + fy

  local xr = cielab_xyz_rescale(fx)
  local yr
  if l > cie_kappa * cie_epsilon then
    yr = math.pow((l + 16) / 116, 3)
  else
    yr = l / cie_kappa
  end
  local zr = cielab_xyz_rescale(fz)

  return ref_x * xr, ref_y * yr, ref_z * zr
end

local function xyz_srgb_rescale(var)
  if var > 0.0031308 then
    return 1.055 * math.pow(var, 1 / 2.4) - 0.055
  else
    return var * 12.92
  end
end

local function xyz_to_srgb(x, y, z)
  local var_x = x
  local var_y = y
  local var_z = z

  local var_r = xyz_srgb_rescale(var_x * 3.2406 + var_y * -1.5372 + var_z * -0.4986)
  local var_g = xyz_srgb_rescale(var_x * -0.9689 + var_y * 1.8758 + var_z * 0.0415)
  local var_b = xyz_srgb_rescale(var_x * 0.0557 + var_y * -0.2040 + var_z * 1.0570)

  return var_r, var_g, var_b 
end

-- get the configuration with defaults
local function color_config()
  local config = configs.get_module('rainbow-identifiers') or {}

  return {
    -- number of bytes to use from the hash. for L*a*b this should be 8
    hash_bytes = config.hash_bytes or 8,
    -- number of colors. due to neovim limitations this gets mapped down to the
    -- usual #rrggbb space instead of #rrrrggggbbbb
    color_count = config.color_count or 16777216,
    -- the lightness of the produced colors
    lightness = config.lightness or 50,
    -- the saturation of the produced colors
    saturation = config.saturation or 15,
  }
end

-- convert a hash number to a color code. the # is not attached
local function hash_to_color(hash, cfg) 
  local bucket = hash % cfg.color_count
  local angle = 2 * math.pi * (bucket / cfg.color_count)
  local a = cfg.saturation * math.cos(angle)
  local b = cfg.saturation * math.sin(angle)
  local x,y,z = cielab_to_xyz(cfg.lightness, a, b)
  local sr,sg,sb = xyz_to_srgb(x, y, z)

  return string.format("%02x%02x%02x", sr * 255, sg * 255, sb * 255)
end

-- calculate a color code for a string. utility function for external code
M.color_code = function(text)
  local config = color_config()
  local code = hash_text(text, config)
  return hash_to_color(code, config)
end

-- callback method for when changes have occurred in the buffer
--
-- skeleton taken from p00f/nvim-ts-rainbow
local function highlight_changes(bufnr, changes, tree, lang)
  if not lang then
    return
  end

  local cfg = color_config()

  for _, change in ipairs(changes) do
    vim.api.nvim_buf_clear_namespace(bufnr, nsid, change[1], change[3] + 1)

    local root = tree:root()
    local query = queries.get_query(lang, 'highlights')
    if query ~= nil then
      for _, node, _ in query:iter_captures(root, bufnr, change[1], change[3] + 1) do
        local hash = hash_to_color(hash_text(ts_utils.get_node_text(node, bufnr)[1], cfg), cfg)
        -- print(node:type() .. " " .. hash .. " " .. vim.inspect(ts_utils.get_node_text(node, bufnr)))
        if (node:type() == "identifier" or node:type() == "property_identifier" or node:type() == "method" or node:type() == "field_identifier" or node:type() == "type_identifier") and hash ~= nil then
          local startRow, startCol, endRow, endCol = node:range()
          defhl(hash, "#" .. hash)
          vim.highlight.range(bufnr, nsid, ( "rainbowident" .. hash ), { startRow, startCol }, { endRow, endCol - 1 }, "blockwise", true)
        end
      end
    end
  end
end

-- apply highlighting to an entire buffer. used on attach
local function highlight_buffer(bufnr)
  local parser = parsers.get_parser(bufnr)
  parser:for_each_tree(function(tree, sub_parser) highlight_changes(bufnr, { { tree:root():range() } }, tree, sub_parser:lang()) end)
end

local attached_buffers = {}
function M.attach(bufnr, lang)
  highlight_buffer(bufnr)
  attached_buffers[bufnr] = true
  local parser = parsers.get_parser(bufnr, lang)
  parser:register_cbs({
    on_changedtree = function(changes, tree)
      if attached_buffers[bufnr] == true then
        highlight_changes(bufnr, changes, tree, lang)
      end
    end
  })
end

function M.detach(bufnr)
  attached_buffers[bufnr] = false
  vim.api.nvim_buf_clear_namespace(bufnr, nsid, 0, -1)
end

return M

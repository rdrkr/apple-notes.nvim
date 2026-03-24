--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Read-only image support for Apple Notes.
---
--- Apple Notes returns images as base64 data URIs in `body of note`, but
--- `set body` silently strips any <img> tags. Therefore, image support is
--- read-only. The actual image files are stored as attachments on disk.
---
---   READ:  base64 <img> in HTML → replace with absolute path before pandoc
---   WRITE: local image references are stripped (images remain untouched in Apple Notes)
---
--- Image files live on disk at:
---   ~/Library/Group Containers/group.com.apple.notes/Accounts/{account_id}/Media/{media_id}/{subfolder}/{filename}
---
--- The {subfolder} is a generated UUID directory (e.g. "1_ABC-DEF-...") that
--- must be discovered via glob since it's not stored in the database.
---
--- @module apple-notes.images
local db = require("apple-notes.db")

local M = {}

--- Base path for Apple Notes data.
local NOTES_BASE = vim.fn.expand("~/Library/Group Containers/group.com.apple.notes")

--- Resolve the on-disk file path for an attachment.
---
--- Globs the media directory to find the subfolder since Apple Notes
--- uses a generated UUID directory that isn't stored in the database.
---
--- @param account_id string The account ZIDENTIFIER
--- @param media_id string The media ZIDENTIFIER
--- @param filename string The media ZFILENAME
--- @return string|nil The absolute file path, or nil if not found
function M.resolve_attachment_path(account_id, media_id, filename)
  if not account_id or account_id == "" or not media_id or media_id == "" then
    return nil
  end

  local media_dir = string.format("%s/Accounts/%s/Media/%s", NOTES_BASE, account_id, media_id)

  -- Find the subfolder via glob (format: "1_UUID" or similar)
  local subfolders = vim.fn.glob(media_dir .. "/*", false, true)
  if not subfolders or #subfolders == 0 then
    return nil
  end

  -- Use the first (usually only) subfolder
  local subfolder = subfolders[1]
  local filepath = subfolder .. "/" .. filename

  if vim.fn.filereadable(filepath) == 1 then
    return filepath
  end

  return nil
end

--- Estimate decoded byte size from a base64 string length.
---
--- Base64 encodes 3 bytes into 4 characters. This gives an approximate
--- file size for matching against on-disk attachment files.
---
--- @param base64_len number Length of the base64 string
--- @return number Estimated decoded byte count
local function estimate_decoded_size(base64_len)
  return math.floor(base64_len * 3 / 4)
end

--- Find the best matching attachment for a base64 image by decoded size.
---
--- Compares the estimated decoded size of the base64 data against the
--- file sizes of available attachments. Returns the closest match.
---
--- @param base64_data string The base64 encoded image data
--- @param attachments table[] The attachment records with resolved paths
--- @return table|nil The best matching attachment, or nil
local function match_attachment_by_size(base64_data, attachments)
  local estimated_size = estimate_decoded_size(#base64_data)
  local best_match = nil
  local best_diff = math.huge

  for _, att in ipairs(attachments) do
    if att._filepath and not att._used then
      local stat = vim.loop.fs_stat(att._filepath)
      if stat then
        local diff = math.abs(stat.size - estimated_size)
        if diff < best_diff then
          best_diff = diff
          best_match = att
        end
      end
    end
  end

  -- Accept if within 5% tolerance (base64 padding can cause small variance)
  if best_match and best_diff <= estimated_size * 0.05 then
    best_match._used = true
    return best_match
  end

  return nil
end

--- Replace base64 <img> tags in HTML with file:// paths to on-disk attachments.
---
--- Fetches attachment data from the database and matches each base64 image
--- to the correct attachment file by comparing decoded size to file size.
--- This runs BEFORE pandoc so the conversion produces clean markdown like
--- `![filename](file:///path/to/image.png)`.
---
--- @param html string The HTML content with base64 <img> tags
--- @param note_id number The note's Z_PK for attachment lookup
--- @param callback fun(result: string) Called with the updated HTML
function M.resolve_images_in_html(html, note_id, callback)
  if not html:match("data:image/") then
    callback(html)
    return
  end

  db.get_attachments(note_id, function(err, attachments)
    if err or not attachments or #attachments == 0 then
      -- No attachment data — strip base64 images to [image] placeholder
      local fallback = html
        :gsub('<img[^>]*src="data:image/[^"]*"[^>]*/>', "[image]")
        :gsub('<img[^>]*src="data:image/[^"]*"[^>]*>', "[image]")
      callback(fallback)
      return
    end

    -- Pre-resolve all attachment file paths
    for _, att in ipairs(attachments) do
      att._filepath = M.resolve_attachment_path(att.account_id, att.media_id, att.filename)
      att._used = false
    end

    -- Replace base64 <img> tags with resolved file paths, matching by size
    local result = html:gsub('<img[^>]*src="data:image/[^;]*;base64,([^"]*)"[^>]*/?>', function(base64_data)
      local att = match_attachment_by_size(base64_data, attachments)
      if not att then
        return "[image]"
      end

      local alt_text = att.filename:match("(.+)%..+$") or att.filename
      return string.format('<img src="%s" alt="%s">', att._filepath, alt_text)
    end)

    callback(result)
  end)
end

--- Strip local image references from markdown before saving.
---
--- Since images can't be written back to Apple Notes via `set body`,
--- replace any image references pointing to the Apple Notes media directory
--- with the original [image] placeholder to avoid data loss or corruption.
---
--- @param markdown string The markdown content with possible local images
--- @return string The markdown with local Apple Notes images replaced by [image]
function M.strip_local_images(markdown)
  -- Match images with absolute paths to Apple Notes media directory
  local result = markdown:gsub("!%[[^%]]*%]%(/Users/[^%)]*group%.com%.apple%.notes[^%)]+%)", "[image]")
  -- Also strip any file:// URIs pointing to Apple Notes
  result = result:gsub("!%[[^%]]*%]%(file://[^%)]+group%.com%.apple%.notes[^%)]+%)", "[image]")
  return result
end

return M

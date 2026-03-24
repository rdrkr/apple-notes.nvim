--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- HTML to Markdown conversion via pandoc.
---
--- Apple Notes stores content as HTML internally. This module converts
--- between HTML and Markdown using pandoc as the conversion engine.
---
--- Apple Notes HTML dialect:
---   - Every block is wrapped in <div>...</div>
---   - Headings: <div><h1>text</h1></div>, <div><h2>text</h2></div>, etc.
---   - Code lines: <div><tt>code</tt></div> (teletype, consecutive = code block)
---   - Empty lines: <div><br></div>
---   - Plain text: <div>text</div> (may be numbered list "1. ..." or bullet "* ...")
---   - Styled spans: <span style="font-size: 24px">text</span> (title heading)
---
--- Pipeline:
---   Read:  AppleScript HTML body → preprocess → pandoc -f html -t gfm → postprocess → buffer
---   Write: buffer → pandoc -f gfm -t html → postprocess_for_apple → AppleScript set body
---
--- @module apple-notes.converter
local job = require("apple-notes.job")

local M = {}

--- Pre-process Apple Notes HTML into standard HTML before pandoc conversion.
---
--- Apple Notes wraps every line in <div>...</div>. Instead of stripping divs
--- (which collapses all lines), this function processes each div as a block
--- and converts Apple's HTML dialect into standard HTML that pandoc understands.
---
--- Handles:
---   - <div><hN>text</hN></div> → <hN>text</hN> (headings)
---   - <div><tt>code</tt></div> → accumulated into <pre><code> blocks
---   - <div><br></div> → empty paragraph
---   - <div>N. text</div> → <li>text</li> in <ol> (numbered lists)
---   - <div>* text</div> → <li>text</li> in <ul> (bullet lists)
---   - <div>text</div> → <p>text</p> (regular paragraphs)
---   - <span style="font-size: 24px"> → <h1> (Apple Notes title style)
---   - <span style="font-size: 18px"> → <h2> (Apple Notes heading style)
---   - <b><hN>text</hN></b> → <hN>text</hN> (bold-wrapped headings)
---   - <object><table>...</table></object> → cleaned table for pandoc
---   - Top-level <ol>, <ul>, <ul class="Apple-dash-list"> → proper lists
---
--- @param html string The raw Apple Notes HTML
--- @return string Standard HTML suitable for pandoc
local function preprocess_html(html)
  -- Phase 1: Strip ghost heading line-break artifacts.
  -- Apple Notes appends <b><span style="font-size:NNpx"><hN><br></hN></span></b>
  -- after real headings, producing empty duplicate headings.
  html = html:gsub('<b><span[^>]*style="[^"]*font%-size:[^"]*"[^>]*><h[1-6]><br></h[1-6]></span></b>', "")
  -- Variant: <font face="..."><span style="font-size:NNpx"><hN><br></hN></span></font>
  html = html:gsub('<font[^>]*><span[^>]*style="[^"]*font%-size:[^"]*"[^>]*><h[1-6]><br></h[1-6]></span></font>', "")
  -- Variant: <font...><hN><br></hN></font> (h3 and below)
  html = html:gsub("<font[^>]*><h[1-6]><br></h[1-6]></font>", "")

  -- Phase 2: Convert remaining styled spans to semantic headings.
  -- Apple Notes title: font-size around 24-28px with bold
  html = html:gsub('<span[^>]*style="[^"]*font%-size:%s*2[4-8]px[^"]*"[^>]*>(.-)</span>', function(content)
    content = content:gsub("^%s*<b>(.-)</b>%s*$", "%1")
    return "<h1>" .. content .. "</h1>"
  end)
  -- Apple Notes heading: font-size around 18-20px with bold
  html = html:gsub('<span[^>]*style="[^"]*font%-size:%s*1[8-9]px[^"]*"[^>]*>(.-)</span>', function(content)
    content = content:gsub("^%s*<b>(.-)</b>%s*$", "%1")
    return "<h2>" .. content .. "</h2>"
  end)

  -- Phase 3: Unwrap <b> around headings: <b><hN>text</hN></b> → <hN>text</hN>
  html = html:gsub("<b>(<h[1-6]>.-</h[1-6]>)</b>", "%1")

  -- Phase 4: Clean tables for pandoc.
  -- Strip <div>...</div> inside table cells to prevent nested div issues
  -- with the main div parser.
  html = html:gsub("(<t[dh][^>]*>)%s*<div>(.-)</div>", "%1%2")
  -- Strip <object> wrapper around tables
  html = html:gsub("<object>%s*(<table.-%s*</table>)%s*</object>", "%1")
  -- Strip [xN] artifacts from AppleScript table output
  html = html:gsub("%[x%d+%]%s*", "")

  -- Phase 5: Normalize top-level lists into div-wrapped format.
  -- Apple Notes uses actual <ol>/<ul> at the top level (not inside divs);
  -- convert them to div-wrapped items so the div processor handles them.
  html = html:gsub("<ul[^>]*>(.-)</ul>", function(list_content)
    local items = {}
    for item in list_content:gmatch("<li>(.-)</li>") do
      local clean_item = item:gsub("<br>%s*$", "")
      table.insert(items, "<div>* " .. clean_item .. "</div>")
    end
    return table.concat(items, "\n")
  end)
  html = html:gsub("<ol[^>]*>(.-)</ol>", function(list_content)
    local items = {}
    local idx = 1
    for item in list_content:gmatch("<li>(.-)</li>") do
      table.insert(items, "<div>" .. idx .. ". " .. item .. "</div>")
      idx = idx + 1
    end
    return table.concat(items, "\n")
  end)

  -- Split into lines for div-by-div processing
  local output = {}
  local in_code = false
  local code_lines = {}
  local in_ol = false
  local in_ul = false

  --- Flush accumulated code lines into a <pre><code> block.
  local function flush_code()
    if #code_lines > 0 then
      table.insert(output, "<pre><code>" .. table.concat(code_lines, "\n") .. "</code></pre>")
      code_lines = {}
    end
    in_code = false
  end

  --- Close any open list.
  local function close_lists()
    if in_ol then
      table.insert(output, "</ol>")
      in_ol = false
    end
    if in_ul then
      table.insert(output, "</ul>")
      in_ul = false
    end
  end

  -- Process each <div>...</div> block
  for div_content in html:gmatch("<div[^>]*>(.-)</div>") do
    -- Check for code line: <tt>...</tt> (possibly wrapped in <font>)
    local tt_content = div_content:match("^%s*<tt>(.-)</tt>%s*$")
    if not tt_content then
      tt_content = div_content:match("^%s*<font[^>]*>%s*<tt>(.-)</tt>%s*</font>%s*$")
    end
    if tt_content then
      if not in_code then
        close_lists()
        in_code = true
      end
      -- <br> inside code is an empty line
      tt_content = tt_content:gsub("<br[^>]*>", "")
      table.insert(code_lines, tt_content)
    else
      -- Not code — flush any accumulated code block
      if in_code then
        flush_code()
      end

      -- Check for heading: <hN>...</hN>
      local hlevel, hcontent = div_content:match("<(h[1-6])[^>]*>(.-)</h[1-6]>")
      if hlevel and hcontent then
        close_lists()
        table.insert(output, "<" .. hlevel .. ">" .. hcontent .. "</" .. hlevel .. ">")

      -- Check for table content: pass through for pandoc
      elseif div_content:match("<table") then
        close_lists()
        -- Strip trailing <br> after table close tag
        local tbl = div_content:gsub("<br[^>]*>%s*$", "")
        -- Promote first row to <thead> — Apple Notes tables always use the first
        -- row as the header, but don't mark it with <th> in the HTML.
        tbl = tbl:gsub("(<table[^>]*>%s*)<tbody>%s*<tr>(.-)</tr>", function(table_open, first_row)
          local header = first_row:gsub("<td([^>]*)>(.-)</td>", function(attrs, cell)
            cell = cell:gsub("</?b>", ""):match("^%s*(.-)%s*$")
            return "<th" .. attrs .. ">" .. cell .. "</th>"
          end)
          return table_open .. "<thead><tr>" .. header .. "</tr></thead>\n<tbody>"
        end, 1)
        table.insert(output, tbl)

      -- Check for empty line: <br> or just whitespace
      elseif div_content:match("^%s*<br[^>]*>%s*$") or div_content:match("^%s*$") then
        close_lists()
        table.insert(output, "<p><br></p>")

      -- Check for numbered list item: starts with "N. "
      elseif div_content:match("^%s*%d+%.%s") then
        if not in_ol then
          close_lists()
          table.insert(output, "<ol>")
          in_ol = true
        end
        local item_text = div_content:match("^%s*%d+%.%s+(.*)")
        table.insert(output, "<li>" .. (item_text or div_content) .. "</li>")

      -- Check for bullet list item: starts with "* "
      elseif div_content:match("^%s*%*%s") then
        if not in_ul then
          close_lists()
          table.insert(output, "<ul>")
          in_ul = true
        end
        local item_text = div_content:match("^%s*%*%s+(.*)")
        table.insert(output, "<li>" .. (item_text or div_content) .. "</li>")

      -- Check for monospace-styled div (Menlo, Courier, monospace fonts)
      elseif div_content:match("[Mm]enlo") or div_content:match("[Cc]ourier") or div_content:match("monospace") then
        -- Extract text content, stripping HTML tags
        local styled = div_content:gsub("<[^>]+>", "")
        if not in_code then
          close_lists()
          in_code = true
        end
        table.insert(code_lines, styled)

      -- Regular paragraph
      else
        close_lists()
        table.insert(output, "<p>" .. div_content .. "</p>")
      end
    end
  end

  -- Flush any remaining code block or list
  if in_code then
    flush_code()
  end
  close_lists()

  return table.concat(output, "\n")
end

--- Clean up pandoc markdown output.
---
--- Removes artifacts that pandoc produces from Apple Notes HTML:
--- escaped list markers, stray backslashes, and excessive blank lines.
---
--- @param md string The raw pandoc markdown output
--- @return string Cleaned markdown
local function postprocess_markdown(md)
  local result = md

  -- Convert 4-space indented code blocks to fenced code blocks.
  -- Fenced blocks are unambiguous and won't be misinterpreted as list
  -- continuations on the write path round-trip.
  local lines_arr = {}
  for line in (result .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines_arr, line)
  end

  local new_lines = {}
  local i = 1
  while i <= #lines_arr do
    local line = lines_arr[i]
    if line:match("^    ") and (i == 1 or lines_arr[i - 1] == "") then
      -- Start of indented code block
      table.insert(new_lines, "```")
      while i <= #lines_arr and (lines_arr[i]:match("^    ") or lines_arr[i] == "") do
        if lines_arr[i] == "" then
          -- Check if next line is also indented (continuation) or not (end of block)
          if i + 1 <= #lines_arr and lines_arr[i + 1]:match("^    ") then
            table.insert(new_lines, "")
            i = i + 1
          else
            break
          end
        else
          table.insert(new_lines, lines_arr[i]:sub(5)) -- strip 4-space indent
          i = i + 1
        end
      end
      table.insert(new_lines, "```")
    else
      table.insert(new_lines, line)
      i = i + 1
    end
  end
  result = table.concat(new_lines, "\n")

  -- Remove standalone backslash lines (pandoc renders <br> as \), but preserve
  -- list separators — a \ between two list blocks must become <!-- --> so pandoc
  -- doesn't merge same-type lists on the write path.
  local bs_lines = {}
  for line in (result .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(bs_lines, line)
  end
  local bs_out = {}
  for idx = 1, #bs_lines do
    local line = bs_lines[idx]
    if line:match("^\\%s*$") then
      -- Find previous non-blank line
      local prev_is_list = false
      for j = idx - 1, 1, -1 do
        if bs_lines[j] ~= "" then
          prev_is_list = bs_lines[j]:match("^%s*[-*+]%s") or bs_lines[j]:match("^%s*%d+[.)]%s") ~= nil
          break
        end
      end
      -- Find next non-blank line
      local next_is_list = false
      for j = idx + 1, #bs_lines do
        if bs_lines[j] ~= "" then
          next_is_list = bs_lines[j]:match("^%s*[-*+]%s") or bs_lines[j]:match("^%s*%d+[.)]%s") ~= nil
          break
        end
      end
      if prev_is_list and next_is_list then
        table.insert(bs_out, "<!-- -->")
      end
      -- Otherwise drop the \ line
    else
      table.insert(bs_out, line)
    end
  end
  result = table.concat(bs_out, "\n")

  -- Remove stray backslashes at end of lines (pandoc line break artifacts).
  -- Lua's $ only matches end-of-string, so also match \ before newlines.
  result = result:gsub("\\%s*\n", "\n")
  result = result:gsub("\\%s*$", "")

  -- Remove escaped brackets around [image] placeholder
  result = result:gsub("\\%[image\\%]", "[image]")

  -- Collapse 3+ consecutive blank lines into 2
  result = result:gsub("\n\n\n+", "\n\n")

  -- Trim leading/trailing whitespace
  result = result:match("^%s*(.-)%s*$") or result

  return result
end

--- Clean up pandoc's HTML output for Apple Notes' `set body` API.
---
--- Apple Notes' AppleScript `set body` accepts standard HTML and converts it
--- internally to its own format (div-wrapped, styled spans for headings, etc.).
--- We only strip pandoc-specific attributes and add separators between
--- consecutive list blocks (Apple Notes merges adjacent lists without a break).
---
--- @param html string The HTML from pandoc
--- @return string Clean HTML suitable for Apple Notes' set body API
local function postprocess_html_for_apple(html)
  -- Strip pandoc-generated id attributes on headings (e.g. id="some-heading")
  html = html:gsub('(<h[1-6]) id="[^"]*"', "%1")

  -- Strip type attribute on ordered lists (e.g. type="1")
  html = html:gsub('<ol type="[^"]*">', "<ol>")

  -- Strip <p> wrappers inside <li> (pandoc uses these for "loose" lists)
  html = html:gsub("<li>%s*<p>(.-)</p>%s*</li>", "<li>%1</li>")

  -- Convert <!-- --> list separators to <br> spacers.
  -- These were inserted by the read path to prevent pandoc from merging
  -- same-type lists. Apple Notes needs <br> to visually separate them.
  html = html:gsub("<!%-%- %-%->", "<br>")

  -- Insert <br> spacers between consecutive block elements.
  -- Apple Notes does not add visual spacing between adjacent blocks unless
  -- there is an explicit <br>. Without this, headings, paragraphs, code blocks,
  -- and lists all run together.
  local lines = {}
  for line in (html .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end

  local result_lines = {}
  local prev_was_block_close = false
  for _, line in ipairs(lines) do
    local is_block_open = line:match("^%s*<h[1-6]")
      or line:match("^%s*<p[> ]")
      or line:match("^%s*<p$")
      or line:match("^%s*<pre")
      or line:match("^%s*<table")
      or line:match("^%s*<ol")
      or line:match("^%s*<ul")
    if prev_was_block_close and is_block_open then
      table.insert(result_lines, "<br>")
    end
    table.insert(result_lines, line)
    prev_was_block_close = line:match("</h[1-6]>%s*$")
      or line:match("</p>%s*$")
      or line:match("</pre>%s*$")
      or line:match("</table>%s*$")
      or line:match("</ol>%s*$")
      or line:match("</ul>%s*$")
  end

  return table.concat(result_lines, "\n")
end

--- Convert HTML to Markdown using pandoc.
---
--- Pre-processes Apple Notes HTML into standard HTML, then uses pandoc
--- with gfm (GitHub Flavored Markdown) for clean output.
---
--- When note_id is provided, base64 <img> tags are replaced with file://
--- paths to the actual image files on disk before pandoc conversion.
---
--- @param html string The HTML content from Apple Notes
--- @param callback fun(err: string|nil, markdown: string|nil) Called with converted content
--- @param note_id number|nil The note's Z_PK for image resolution (optional)
function M.html_to_md(html, callback, note_id)
  if not html or html == "" then
    callback(nil, "")
    return
  end

  --- Run pandoc conversion after image resolution.
  --- @param resolved_html string HTML with images resolved or stripped
  local function do_convert(resolved_html)
    local cleaned = preprocess_html(resolved_html)

    job.run(
      { "pandoc", "-f", "html", "-t", "gfm", "--wrap=none" },
      { input = cleaned, timeout = 10000 },
      function(err, result)
        if err then
          callback("HTML to Markdown conversion failed: " .. err, nil)
          return
        end
        callback(nil, postprocess_markdown(result or ""))
      end
    )
  end

  -- Resolve base64 images to file paths before pandoc if note_id provided
  if note_id and html:match("data:image/") then
    local images = require("apple-notes.images")
    images.resolve_images_in_html(html, note_id, do_convert)
  else
    do_convert(html)
  end
end

--- Convert Markdown to HTML using pandoc, then post-process for Apple Notes.
---
--- Converts gfm markdown to HTML, then transforms pandoc's semantic HTML
--- into Apple Notes' div-wrapped format for proper display in the app.
---
--- Any file:// image references are stripped before conversion since Apple
--- Notes' `set body` silently drops <img> tags. Images in Apple Notes are
--- managed as attachments and are not affected by body updates.
---
--- @param markdown string The Markdown content from the buffer
--- @param callback fun(err: string|nil, html: string|nil) Called with converted content
function M.md_to_html(markdown, callback)
  if not markdown or markdown == "" then
    callback(nil, "")
    return
  end

  -- Strip file:// images before conversion (read-only, can't write back)
  local images = require("apple-notes.images")
  local clean_md = images.strip_local_images(markdown)

  job.run({ "pandoc", "-f", "gfm", "-t", "html" }, { input = clean_md, timeout = 10000 }, function(err, result)
    if err then
      callback("Markdown to HTML conversion failed: " .. err, nil)
      return
    end
    callback(nil, postprocess_html_for_apple(result or ""))
  end)
end

--- Check if pandoc is available and return its version.
---
--- @param callback fun(err: string|nil, version: string|nil)
function M.check_pandoc(callback)
  job.run({ "pandoc", "--version" }, { timeout = 5000 }, function(err, result)
    if err then
      callback("pandoc not found: " .. err, nil)
      return
    end
    local version = (result or ""):match("pandoc ([%d%.]+)")
    callback(nil, version or "unknown")
  end)
end

return M

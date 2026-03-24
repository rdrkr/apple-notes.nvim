--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Tests for tag extraction logic.
---
--- Run with: nvim --headless -c "lua require('tests.test_tags')()"

--- Import the extract_tags_from_text function.
--- It's local to db.lua, so we test it indirectly by loading a test-only accessor.
--- For now, we replicate the function here for isolated testing.
local function extract_tags_from_text(text)
  local tags = {}
  if not text or text == "" then
    return tags
  end
  local plaintext = text:gsub("<[^>]+>", " ")
  local padded = " " .. plaintext
  for tag in padded:gmatch("[%s%p]#(%w+)") do
    if #tag >= 2 then
      tags["#" .. tag] = true
    end
  end
  return tags
end

local function assert_eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %q, got %q", msg or "FAIL", tostring(expected), tostring(actual)))
  end
end

local function assert_has_tag(tags, tag, msg)
  if not tags[tag] then
    error(string.format("%s: expected tag %q to be present", msg or "FAIL", tag))
  end
end

local function assert_no_tag(tags, tag, msg)
  if tags[tag] then
    error(string.format("%s: expected tag %q to NOT be present", msg or "FAIL", tag))
  end
end

local function count_tags(tags)
  local n = 0
  for _ in pairs(tags) do
    n = n + 1
  end
  return n
end

local function test_single_tag()
  local tags = extract_tags_from_text("Hello #world")
  assert_has_tag(tags, "#world", "should find #world")
  assert_eq(1, count_tags(tags), "should have exactly 1 tag")
end

local function test_multiple_tags()
  local tags = extract_tags_from_text("Hello #work and #life")
  assert_has_tag(tags, "#work", "should find #work")
  assert_has_tag(tags, "#life", "should find #life")
  assert_eq(2, count_tags(tags), "should have exactly 2 tags")
end

local function test_tag_at_start()
  local tags = extract_tags_from_text("#first word")
  assert_has_tag(tags, "#first", "should find tag at start of text")
end

local function test_duplicate_tags()
  local tags = extract_tags_from_text("#work and #work again")
  assert_has_tag(tags, "#work", "should find #work")
  assert_eq(1, count_tags(tags), "duplicates should be deduplicated")
end

local function test_case_sensitivity()
  local tags = extract_tags_from_text("#Work and #work")
  assert_has_tag(tags, "#Work", "should find #Work")
  assert_has_tag(tags, "#work", "should find #work")
  assert_eq(2, count_tags(tags), "#Work and #work are separate tags")
end

local function test_url_with_hash()
  local tags = extract_tags_from_text("Visit https://example.com/page#section")
  -- The # in URL is preceded by "page" (alphanumeric), not whitespace/punctuation
  -- so it should not match
  assert_eq(0, count_tags(tags), "# in URL should not be a tag")
end

local function test_hex_color()
  local tags = extract_tags_from_text("Color is #FF5733")
  -- #FF5733 would match as a tag since it's preceded by space
  -- This is a known limitation documented in the plan
  assert_has_tag(tags, "#FF5733", "hex colors are treated as tags (known limitation)")
end

local function test_html_stripped()
  local tags = extract_tags_from_text("<p>Hello #world</p> <div>#test</div>")
  assert_has_tag(tags, "#world", "should find tag in HTML content")
  assert_has_tag(tags, "#test", "should find tag after stripping HTML")
end

local function test_short_tag_rejected()
  local tags = extract_tags_from_text("This #a is too short")
  assert_eq(0, count_tags(tags), "single character tags should be rejected")
end

local function test_minimum_length_tag()
  local tags = extract_tags_from_text("This #ab is minimum")
  assert_has_tag(tags, "#ab", "two character tags should be accepted")
end

local function test_empty_input()
  local tags = extract_tags_from_text("")
  assert_eq(0, count_tags(tags), "empty string should return no tags")
end

local function test_nil_input()
  local tags = extract_tags_from_text(nil)
  assert_eq(0, count_tags(tags), "nil input should return no tags")
end

local function test_tag_after_punctuation()
  local tags = extract_tags_from_text("Check this: #important!")
  assert_has_tag(tags, "#important", "tag after colon should be found")
end

local function test_tag_in_parentheses()
  local tags = extract_tags_from_text("Note (#todo) here")
  assert_has_tag(tags, "#todo", "tag in parentheses should be found")
end

return function()
  local tests = {
    test_single_tag,
    test_multiple_tags,
    test_tag_at_start,
    test_duplicate_tags,
    test_case_sensitivity,
    test_url_with_hash,
    test_hex_color,
    test_html_stripped,
    test_short_tag_rejected,
    test_minimum_length_tag,
    test_empty_input,
    test_nil_input,
    test_tag_after_punctuation,
    test_tag_in_parentheses,
  }

  local passed = 0
  local failed = 0

  for _, test in ipairs(tests) do
    local ok, err = pcall(test)
    if ok then
      passed = passed + 1
    else
      failed = failed + 1
      print("FAIL: " .. tostring(err))
    end
  end

  print(string.format("\n%d passed, %d failed", passed, failed))

  if failed > 0 then
    os.exit(1)
  end
end

--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Tests for template variable substitution.
---
--- Run with: nvim --headless -c "lua require('tests.test_templates')()"

--- Replicate the function from init.lua for isolated testing.
--- The actual init module requires Neovim plugin infrastructure.
local init = {}

--- @param body string The template body with {{variable}} placeholders
--- @param title string The note title
--- @return string The body with variables replaced
function init._substitute_template_vars(body, title)
  local result = body
  result = result:gsub("{{title}}", title or "")
  result = result:gsub("{{date}}", os.date("%Y-%m-%d"))
  result = result:gsub("{{time}}", os.date("%H:%M"))
  return result
end

local function assert_eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %q, got %q", msg or "FAIL", expected, actual))
  end
end

local function test_title_substitution()
  local result = init._substitute_template_vars("# {{title}}", "My Note")
  assert_eq("# My Note", result, "{{title}} should be replaced with the title")
end

local function test_date_substitution()
  local result = init._substitute_template_vars("Date: {{date}}", "Test")
  local expected_date = os.date("%Y-%m-%d")
  assert_eq("Date: " .. expected_date, result, "{{date}} should be replaced with YYYY-MM-DD")
end

local function test_time_substitution()
  local result = init._substitute_template_vars("Time: {{time}}", "Test")
  local expected_time = os.date("%H:%M")
  assert_eq("Time: " .. expected_time, result, "{{time}} should be replaced with HH:MM")
end

local function test_multiple_variables()
  local result = init._substitute_template_vars("# {{title}}\n\nCreated: {{date}} {{time}}", "My Note")
  local expected = "# My Note\n\nCreated: " .. os.date("%Y-%m-%d") .. " " .. os.date("%H:%M")
  assert_eq(expected, result, "multiple variables should all be replaced")
end

local function test_no_variables()
  local body = "Just plain text, no variables here."
  local result = init._substitute_template_vars(body, "Title")
  assert_eq(body, result, "text without variables should pass through unchanged")
end

local function test_unknown_variable()
  local body = "Hello {{unknown}} world"
  local result = init._substitute_template_vars(body, "Title")
  assert_eq(body, result, "unknown {{variables}} should pass through as literal text")
end

local function test_repeated_title()
  local result = init._substitute_template_vars("{{title}} - {{title}}", "Note")
  assert_eq("Note - Note", result, "{{title}} used twice should both be replaced")
end

local function test_empty_title()
  local result = init._substitute_template_vars("# {{title}}", "")
  assert_eq("# ", result, "empty title should result in empty substitution")
end

return function()
  local tests = {
    test_title_substitution,
    test_date_substitution,
    test_time_substitution,
    test_multiple_variables,
    test_no_variables,
    test_unknown_variable,
    test_repeated_title,
    test_empty_title,
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

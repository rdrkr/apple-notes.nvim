--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Tests for the sanitize module.
---
--- Run with: nvim --headless -c "lua require('tests.test_sanitize')()"
local sanitize = require("apple-notes.sanitize")

local function assert_eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %q, got %q", msg or "FAIL", expected, actual))
  end
end

local function test_sql_nil()
  assert_eq("", sanitize.sql(nil), "sql(nil) should return empty string")
end

local function test_sql_empty()
  assert_eq("", sanitize.sql(""), "sql('') should return empty string")
end

local function test_sql_normal_string()
  assert_eq("hello world", sanitize.sql("hello world"), "normal string should pass through")
end

local function test_sql_single_quotes()
  assert_eq("it''s", sanitize.sql("it's"), "single quotes should be doubled")
end

local function test_sql_injection_attempt()
  local input = "'; DROP TABLE ZICCLOUDSYNCINGOBJECT; --"
  local expected = "''; DROP TABLE ZICCLOUDSYNCINGOBJECT; --"
  assert_eq(expected, sanitize.sql(input), "SQL injection should be escaped")
end

local function test_sql_null_bytes()
  assert_eq("hello", sanitize.sql("hel\0lo"), "null bytes should be stripped")
end

local function test_applescript_nil()
  assert_eq("", sanitize.applescript(nil), "applescript(nil) should return empty string")
end

local function test_applescript_empty()
  assert_eq("", sanitize.applescript(""), "applescript('') should return empty string")
end

local function test_applescript_normal_string()
  assert_eq("hello world", sanitize.applescript("hello world"), "normal string should pass through")
end

local function test_applescript_double_quotes()
  assert_eq('say \\"hello\\"', sanitize.applescript('say "hello"'), "double quotes should be escaped")
end

local function test_applescript_backslashes()
  assert_eq("path\\\\to\\\\file", sanitize.applescript("path\\to\\file"), "backslashes should be escaped")
end

local function test_applescript_null_bytes()
  assert_eq("hello", sanitize.applescript("hel\0lo"), "null bytes should be stripped")
end

local function test_applescript_injection_attempt()
  local input = '" & do shell script "rm -rf /" & "'
  local result = sanitize.applescript(input)
  -- Should NOT contain unescaped quotes
  assert(not result:match('^"'), "AppleScript injection should be escaped: " .. result)
end

return function()
  local tests = {
    test_sql_nil,
    test_sql_empty,
    test_sql_normal_string,
    test_sql_single_quotes,
    test_sql_injection_attempt,
    test_sql_null_bytes,
    test_applescript_nil,
    test_applescript_empty,
    test_applescript_normal_string,
    test_applescript_double_quotes,
    test_applescript_backslashes,
    test_applescript_null_bytes,
    test_applescript_injection_attempt,
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

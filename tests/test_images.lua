--- Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

--- Tests for the images module (pure logic only).
---
--- Run with: nvim --headless -c "lua require('tests.test_images')()"

--- Replicate the pure function from images.lua for isolated testing.
local images = {}

--- Strip local image references from markdown before saving.
---
--- Since images can't be written back to Apple Notes via `set body`,
--- replace any image references pointing to the Apple Notes media directory
--- with the original [image] placeholder to avoid data loss or corruption.
---
--- @param markdown string The markdown content with possible local images
--- @return string The markdown with local Apple Notes images replaced by [image]
function images.strip_local_images(markdown)
  -- Match images with absolute paths to Apple Notes media directory
  local result = markdown:gsub("!%[[^%]]*%]%(/Users/[^%)]*group%.com%.apple%.notes[^%)]+%)", "[image]")
  -- Also strip any file:// URIs pointing to Apple Notes
  result = result:gsub("!%[[^%]]*%]%(file://[^%)]+group%.com%.apple%.notes[^%)]+%)", "[image]")
  return result
end

local function assert_eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %q, got %q", msg or "FAIL", expected, actual))
  end
end

local function test_strip_absolute_path()
  local input =
    "Hello\n\n![photo](/Users/me/Library/Group Containers/group.com.apple.notes/Accounts/abc/Media/def/1_UUID/image.png)\n\nWorld"
  local expected = "Hello\n\n[image]\n\nWorld"
  assert_eq(expected, images.strip_local_images(input), "should strip absolute paths to Apple Notes media")
end

local function test_strip_file_uri()
  local input =
    "![photo](file:///Users/me/Library/Group%20Containers/group.com.apple.notes/Accounts/abc/Media/def/1_UUID/image.png)"
  local expected = "[image]"
  assert_eq(expected, images.strip_local_images(input), "should strip file:// URIs to Apple Notes media")
end

local function test_strip_multiple()
  local input =
    "![a](/Users/me/Library/Group Containers/group.com.apple.notes/a.png) text ![b](/Users/me/Library/Group Containers/group.com.apple.notes/b.jpg)"
  local expected = "[image] text [image]"
  assert_eq(expected, images.strip_local_images(input), "should strip multiple Apple Notes images")
end

local function test_no_images()
  local input = "Hello world, no images here"
  assert_eq(input, images.strip_local_images(input), "should pass through text without images")
end

local function test_preserves_external_urls()
  local input = "![icon](https://example.com/icon.png)"
  assert_eq(input, images.strip_local_images(input), "should preserve non-Apple Notes URLs")
end

local function test_preserves_other_local_images()
  local input = "![photo](/Users/me/Downloads/screenshot.png)"
  assert_eq(input, images.strip_local_images(input), "should preserve local images not in Apple Notes directory")
end

local function test_preserves_other_file_uris()
  local input = "![photo](file:///tmp/screenshot.png)"
  assert_eq(input, images.strip_local_images(input), "should preserve file:// URIs not pointing to Apple Notes")
end

local function test_alt_text_with_spaces()
  local input =
    "![Screen Shot 2022-10-25](/Users/me/Library/Group Containers/group.com.apple.notes/Accounts/abc/Media/def/1_UUID/screenshot.png)"
  local expected = "[image]"
  assert_eq(expected, images.strip_local_images(input), "should handle alt text with spaces")
end

return function()
  local tests = {
    test_strip_absolute_path,
    test_strip_file_uri,
    test_strip_multiple,
    test_no_images,
    test_preserves_external_urls,
    test_preserves_other_local_images,
    test_preserves_other_file_uris,
    test_alt_text_with_spaces,
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

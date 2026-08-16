-- DICK/OS argument printer
-- Version: 0.1.0-unstable

local arguments = { ... }

-- Native commands receive runtime context in slot one. Echo intentionally
-- ignores it and joins only the user-supplied argument strings.
table.remove(arguments, 1)

if arguments[1] == "--help" then
    print("Usage: echo [arguments...]")
    return
end

for index, value in ipairs(arguments) do
    arguments[index] = tostring(value)
end

print(table.concat(arguments, " "))

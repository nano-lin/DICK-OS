-- Host-side tests for the DICK/OS password backend
-- Run with: lua tests/password_test.lua

local program = assert(loadfile("src/dickos/lib/password.lua"))
local password = program()

-- Published SHA-256 vectors from FIPS 180-4 examples.
assert(password.sha256("") ==
    "e3b0c44298fc1c149afbf4c8996fb924" ..
    "27ae41e4649b934ca495991b7852b855")
assert(password.sha256("abc") ==
    "ba7816bf8f01cfea414140de5dae2223" ..
    "b00361a396177a9cb410ff61f20015ad")
assert(password.sha256(
    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
) == "248d6a61d20638b8e5c026930c3e6039" ..
    "a33ce45964ff2167f6ecedd419db06c1")

-- RFC 4231 HMAC-SHA256 test case 1.
assert(password.hmacSHA256(
    string.rep(string.char(0x0b), 20),
    "Hi There"
) == "b0344c61d8db38535ca8afceaf0bf12b" ..
    "881dc200c9833da726e9376c2e32cff7")
assert(password.hmacSHA256(
    string.rep(string.char(0xaa), 131),
    "Test Using Larger Than Block-Size Key - Hash Key First"
) == "60e431591ee0b67f0d8a26aacbf5b77f" ..
    "8e0bc6213728c5140546040f0ee37f54")

-- PBKDF2-HMAC-SHA256 vector published in RFC 7914 section 11. Its 64-byte
-- output also exercises PBKDF2's second output block.
assert(password.pbkdf2("passwd", "salt", 1, 64) ==
    "55ac046e56e3089fec1691c22544b605" ..
    "f94185216dde0465e68b9d57c20dacbc" ..
    "49ca9cccf179b645991664b39d77ef31" ..
    "7c71b845b1e30bd509112041d3a19783")
assert(password.pbkdf2("password", "salt", 2, 32) ==
    "ae4d0c95af6b46d32d0adff928f06dd" ..
    "02a303f8ef3c251dfd6e2d85a95474c43")

-- Desktop Lua has no CC:T `sleep`, so the module accepts a private per-instance
-- callback for this scheduling test. The same input is derived once without
-- and once with cooperative yields. Equal digests prove scheduling does not
-- become part of PBKDF2's byte computation, while the counter proves the
-- 256-round path actually ran.
local yieldCount = 0
local yieldingPassword = program({
    cooperativeYield = function()
        yieldCount = yieldCount + 1
    end,
})
local uninterruptedDigest = password.pbkdf2(
    "yield-test-password",
    "yield-test-salt",
    512,
    32
)
local yieldedDigest = yieldingPassword.pbkdf2(
    "yield-test-password",
    "yield-test-salt",
    512,
    32
)
assert(yieldedDigest == uninterruptedDigest)
assert(yieldCount == 2)

-- A termination raised by the cooperative callback must escape PBKDF2. The
-- production callback is CC:T `sleep(0)`, which raises the same value when the
-- user presses Ctrl+T.
local terminatingPassword = program({
    cooperativeYield = function()
        error("Terminated", 0)
    end,
})
local derivationSucceeded, derivationError = pcall(
    terminatingPassword.pbkdf2,
    "yield-test-password",
    "yield-test-salt",
    256,
    32
)
assert(not derivationSucceeded)
assert(tostring(derivationError) == "Terminated")

local valid, validationError = password.validatePassword("12345678")
assert(valid, tostring(validationError))
assert(not password.validatePassword("1234567"))
assert(password.validatePassword(string.rep("x", 128)))
assert(not password.validatePassword(string.rep("x", 129)))
assert(not password.validatePassword(nil))

-- Tests select the documented minimum explicitly. Production callers omit the
-- override and retain `defaultIterations`; the assertion prevents a test-only
-- value from silently replacing that production constant.
assert(password.defaultIterations == 4096)
local firstVerifier = assert(password.createVerifier(
    "correct horse",
    "machine:user",
    password.minimumIterations
))
local secondVerifier = assert(password.createVerifier(
    "correct horse",
    "machine:user",
    password.minimumIterations
))

assert(firstVerifier.salt ~= secondVerifier.salt)
assert(firstVerifier.digest ~= secondVerifier.digest)
assert(firstVerifier.algorithm == "pbkdf2-hmac-sha256")
assert(firstVerifier.iterations == password.minimumIterations)
assert(#firstVerifier.salt == 32)
assert(#firstVerifier.digest == 64)
assert(string.match(firstVerifier.salt, "^[0-9a-f]+$"))
assert(string.match(firstVerifier.digest, "^[0-9a-f]+$"))
assert(password.validateVerifier(firstVerifier))
assert(password.verify("correct horse", firstVerifier))
assert(not password.verify("wrong horse!", firstVerifier))

local malformed = {
    algorithm = firstVerifier.algorithm,
    iterations = password.maximumIterations + 1,
    salt = firstVerifier.salt,
    digest = firstVerifier.digest,
}
assert(not password.validateVerifier(malformed))
local matched, malformedError = password.verify("correct horse", malformed)
assert(not matched)
assert(type(malformedError) == "string")

for fieldName, badValue in pairs({
    algorithm = "unsupported",
    salt = "not-hex",
    digest = "00",
}) do
    local candidate = {
        algorithm = firstVerifier.algorithm,
        iterations = firstVerifier.iterations,
        salt = firstVerifier.salt,
        digest = firstVerifier.digest,
    }
    candidate[fieldName] = badValue
    assert(not password.validateVerifier(candidate))
end

for _, badIterations in ipairs({
    password.minimumIterations - 1,
    password.maximumIterations + 1,
}) do
    local candidate = {
        algorithm = firstVerifier.algorithm,
        iterations = badIterations,
        salt = firstVerifier.salt,
        digest = firstVerifier.digest,
    }
    assert(not password.validateVerifier(candidate))
end

-- The comparison helper is intentionally private. Inspect its implementation
-- as a regression guard: the loop spans the maximum input length and the only
-- equality return follows that loop, rather than returning at first mismatch.
local sourceFile = assert(io.open("src/dickos/lib/password.lua", "rb"))
local sourceText = assert(sourceFile:read("*a"))
sourceFile:close()
assert(string.find(sourceText, "for index = 1, maximumLength do", 1, true))
assert(string.find(sourceText, "return difference == 0", 1, true))

io.stdout:write("password tests: PASS\n")

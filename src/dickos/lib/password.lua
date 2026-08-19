-- DICK/OS password verifier backend
-- Version: 0.1.0-unstable

-- Password policy and password cryptography live in this isolated module so
-- login, passwd, and the installer cannot quietly drift to different rules.
-- PBKDF2-HMAC-SHA256 is a published standard construction: SHA-256 provides
-- the digest, HMAC turns it into a keyed pseudorandom function, and PBKDF2
-- repeats that function to make each password guess deliberately expensive.
-- This implementation follows those standard algorithms; it does not invent
-- a DICK/OS-specific hash.
local password = {
    algorithm = "pbkdf2-hmac-sha256",
    defaultIterations = 4096,
    minimumIterations = 1000,
    maximumIterations = 100000,
    derivedKeyBytes = 32,
    saltBytes = 16,
    minimumPasswordBytes = 8,
    maximumPasswordBytes = 128,
}

-- A top-level Lua chunk receives values passed by its caller through `...`.
-- Normal DICK/OS callers pass nothing. Host-side tests may pass a table with a
-- `cooperativeYield` callback so the scheduling path can be exercised even
-- though ordinary desktop Lua does not provide CC:T's global `sleep` API.
-- The callback remains private to this module instance; it is not a password
-- API and cannot change the bytes processed by PBKDF2.
local moduleOptions = ...
local injectedCooperativeYield = nil

if moduleOptions ~= nil then
    assert(type(moduleOptions) == "table",
        "Password module options must be a table")
    assert(moduleOptions.cooperativeYield == nil or
        type(moduleOptions.cooperativeYield) == "function",
        "Password cooperative yield option must be a function")
    injectedCooperativeYield = moduleOptions.cooperativeYield
end

local band = assert(bit32 and bit32.band, "bit32.band is required")
local bor = assert(bit32 and bit32.bor, "bit32.bor is required")
local bxor = assert(bit32 and bit32.bxor, "bit32.bxor is required")
local bnot = assert(bit32 and bit32.bnot, "bit32.bnot is required")
local rshift = assert(bit32 and bit32.rshift, "bit32.rshift is required")
local rrotate = assert(bit32 and bit32.rrotate, "bit32.rrotate is required")

local UINT32 = 4294967296
local SHA256_BLOCK_BYTES = 64
local PBKDF2_ROUNDS_PER_YIELD = 256
local saltCounter = 0

local SHA256_INITIAL = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

local SHA256_ROUND = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- Lua 5.2 numbers are doubles, while bit32 operations explicitly return the
-- low 32 bits required by SHA-256. The intermediate sum is still exact: each
-- round adds only a handful of 32-bit integers, far below double's 53-bit
-- exact-integer limit.
local function add32(...)
    local total = 0

    for index = 1, select("#", ...) do
        total = total + select(index, ...)
    end

    return band(total, 0xffffffff)
end

local function wordToBytes(word)
    return string.char(
        band(rshift(word, 24), 0xff),
        band(rshift(word, 16), 0xff),
        band(rshift(word, 8), 0xff),
        band(word, 0xff)
    )
end

local function bytesToWord(text, position)
    local a, b, c, d = string.byte(text, position, position + 3)

    return add32(
        a * 0x1000000,
        b * 0x10000,
        c * 0x100,
        d
    )
end

-- SHA-256 pads a message with one set bit, enough zero bytes to leave eight
-- bytes in the final block, then the original bit length as a 64-bit big-endian
-- integer. Splitting that length into high/low 32-bit words avoids depending
-- on native 64-bit integer support which Lua 5.2 does not promise.
local function padSHA256Message(message)
    local bitLength = #message * 8
    local highLength = math.floor(bitLength / UINT32)
    local lowLength = bitLength % UINT32
    local zeroBytes = (56 - ((#message + 1) % 64)) % 64

    return message .. "\128" .. string.rep("\0", zeroBytes) ..
        wordToBytes(highLength) .. wordToBytes(lowLength)
end

local function sha256Raw(message)
    assert(type(message) == "string", "SHA-256 input must be text")

    local hash = {}

    for index = 1, 8 do
        hash[index] = SHA256_INITIAL[index]
    end

    local padded = padSHA256Message(message)

    for blockStart = 1, #padded, SHA256_BLOCK_BYTES do
        local words = {}

        for index = 1, 16 do
            words[index] = bytesToWord(padded, blockStart + (index - 1) * 4)
        end

        for index = 17, 64 do
            local previous15 = words[index - 15]
            local previous2 = words[index - 2]
            local sigma0 = bxor(
                rrotate(previous15, 7),
                rrotate(previous15, 18),
                rshift(previous15, 3)
            )
            local sigma1 = bxor(
                rrotate(previous2, 17),
                rrotate(previous2, 19),
                rshift(previous2, 10)
            )

            words[index] = add32(
                words[index - 16],
                sigma0,
                words[index - 7],
                sigma1
            )
        end

        local a, b, c, d = hash[1], hash[2], hash[3], hash[4]
        local e, f, g, h = hash[5], hash[6], hash[7], hash[8]

        for index = 1, 64 do
            local capitalSigma1 = bxor(
                rrotate(e, 6),
                rrotate(e, 11),
                rrotate(e, 25)
            )
            local choose = bxor(band(e, f), band(bnot(e), g))
            local temporary1 = add32(
                h,
                capitalSigma1,
                choose,
                SHA256_ROUND[index],
                words[index]
            )
            local capitalSigma0 = bxor(
                rrotate(a, 2),
                rrotate(a, 13),
                rrotate(a, 22)
            )
            local majority = bxor(
                band(a, b),
                band(a, c),
                band(b, c)
            )
            local temporary2 = add32(capitalSigma0, majority)

            h = g
            g = f
            f = e
            e = add32(d, temporary1)
            d = c
            c = b
            b = a
            a = add32(temporary1, temporary2)
        end

        hash[1] = add32(hash[1], a)
        hash[2] = add32(hash[2], b)
        hash[3] = add32(hash[3], c)
        hash[4] = add32(hash[4], d)
        hash[5] = add32(hash[5], e)
        hash[6] = add32(hash[6], f)
        hash[7] = add32(hash[7], g)
        hash[8] = add32(hash[8], h)
    end

    local output = {}

    for index = 1, 8 do
        output[index] = wordToBytes(hash[index])
    end

    return table.concat(output)
end

local function bytesToHex(bytes)
    return (string.gsub(bytes, ".", function(character)
        return string.format("%02x", string.byte(character))
    end))
end

local function hexToBytes(hex)
    if type(hex) ~= "string" or #hex % 2 ~= 0 or
        string.match(hex, "^[0-9a-f]+$") == nil then
        return nil
    end

    return (string.gsub(hex, "..", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function xorBytes(left, right)
    local output = {}

    for index = 1, #left do
        output[index] = string.char(bxor(
            string.byte(left, index),
            string.byte(right, index)
        ))
    end

    return table.concat(output)
end

local function hmacSHA256Raw(key, message)
    if #key > SHA256_BLOCK_BYTES then
        key = sha256Raw(key)
    end

    key = key .. string.rep("\0", SHA256_BLOCK_BYTES - #key)
    local innerPad = {}
    local outerPad = {}

    for index = 1, SHA256_BLOCK_BYTES do
        local keyByte = string.byte(key, index)

        innerPad[index] = string.char(bxor(keyByte, 0x36))
        outerPad[index] = string.char(bxor(keyByte, 0x5c))
    end

    return sha256Raw(
        table.concat(outerPad) ..
        sha256Raw(table.concat(innerPad) .. message)
    )
end

-- Give CC:T's cooperative scheduler control after a bounded amount of KDF
-- work. `sleep(0)` is a documented public CC:T API: CC:T rounds the delay up
-- to one server tick, so yielding too often would add visible runtime cost.
-- One yield per 256 PBKDF2 rounds reduces each uninterrupted pure-Lua batch to
-- one sixteenth of a production verifier and adds only 16 scheduler points to
-- its 4096 rounds. The exact runtime margin still requires Minecraft testing.
--
-- Desktop Lua has no global `sleep`, so host crypto tests simply continue. A
-- test may inject the callback above to prove the yield path is used. Neither
-- path is protected with `pcall`: if CC:T raises `Terminated` while sleeping,
-- it must propagate to the DICK shell as an ordinary Ctrl+T child termination.
-- Yielding is only runtime scheduling; it is not part of PBKDF2 and provides no
-- additional cryptographic protection.
local function cooperativeYield()
    if injectedCooperativeYield ~= nil then
        injectedCooperativeYield()
        return
    end

    if type(sleep) == "function" then
        sleep(0)
    end
end

-- PBKDF2 generates successive blocks U1, U2, ... and XORs every U in a block.
-- Iterations are validated here too so malformed direct calls cannot create an
-- accidental unbounded loop. `derivedBytes` is capped because DICK/OS password
-- verifiers need one SHA-256-sized key, not a general key-export facility.
local function pbkdf2Raw(plainPassword, salt, iterations, derivedBytes)
    assert(type(plainPassword) == "string", "PBKDF2 password must be text")
    assert(type(salt) == "string", "PBKDF2 salt must be text")
    assert(type(iterations) == "number" and
        iterations == math.floor(iterations) and iterations >= 1 and
        iterations <= password.maximumIterations,
        "PBKDF2 iterations are outside the supported range")
    assert(type(derivedBytes) == "number" and
        derivedBytes == math.floor(derivedBytes) and derivedBytes >= 1 and
        derivedBytes <= 64,
        "PBKDF2 derived length is outside the supported range")

    local blockCount = math.ceil(derivedBytes / password.derivedKeyBytes)
    local derivedBlocks = {}

    for blockIndex = 1, blockCount do
        local u = hmacSHA256Raw(
            plainPassword,
            salt .. wordToBytes(blockIndex)
        )
        local accumulated = u
        local roundsSinceYield = 1

        for _ = 2, iterations do
            u = hmacSHA256Raw(plainPassword, u)
            accumulated = xorBytes(accumulated, u)
            roundsSinceYield = roundsSinceYield + 1

            if roundsSinceYield >= PBKDF2_ROUNDS_PER_YIELD then
                cooperativeYield()
                roundsSinceYield = 0
            end
        end

        derivedBlocks[#derivedBlocks + 1] = accumulated
    end

    return string.sub(table.concat(derivedBlocks), 1, derivedBytes)
end

function password.sha256(message)
    return bytesToHex(sha256Raw(message))
end

function password.hmacSHA256(key, message)
    assert(type(key) == "string", "HMAC key must be text")
    assert(type(message) == "string", "HMAC message must be text")

    return bytesToHex(hmacSHA256Raw(key, message))
end

function password.pbkdf2(plainPassword, salt, iterations, derivedBytes)
    return bytesToHex(pbkdf2Raw(
        plainPassword,
        salt,
        iterations,
        derivedBytes or password.derivedKeyBytes
    ))
end

-- Password length is measured in bytes because CC:T strings are byte strings,
-- not Unicode code-point containers. No composition rules are imposed: length
-- bounds control resource use without rejecting passphrases for arbitrary
-- uppercase/digit/symbol requirements.
function password.validatePassword(plainPassword)
    if type(plainPassword) ~= "string" then
        return false, "Password must be text."
    end

    if #plainPassword < password.minimumPasswordBytes then
        return false, "Password must contain at least 8 bytes."
    end

    if #plainPassword > password.maximumPasswordBytes then
        return false, "Password must contain at most 128 bytes."
    end

    return true, nil
end

local function validHexLength(value, byteLength)
    return type(value) == "string" and #value == byteLength * 2 and
        string.match(value, "^[0-9a-f]+$") ~= nil
end

function password.validateVerifier(verifier)
    if type(verifier) ~= "table" then
        return false, "Password verifier must be a table."
    end

    if verifier.algorithm ~= password.algorithm then
        return false, "Unsupported password verifier algorithm."
    end

    if type(verifier.iterations) ~= "number" or
        verifier.iterations ~= math.floor(verifier.iterations) or
        verifier.iterations < password.minimumIterations or
        verifier.iterations > password.maximumIterations then
        return false, "Password verifier iteration count is outside policy."
    end

    if not validHexLength(verifier.salt, password.saltBytes) then
        return false, "Password verifier salt is malformed."
    end

    if not validHexLength(verifier.digest, password.derivedKeyBytes) then
        return false, "Password verifier digest is malformed."
    end

    return true, nil
end

-- Salt is public uniqueness input, not a secret key. CC:T does not document a
-- cryptographically secure random generator, so this combines changing UTC
-- time, computer identity, uptime, a per-module counter, optional installation
-- context, and best-effort PRNG output, then hashes them to a fixed 16 bytes.
-- This does not make the salt unpredictable or provide CSPRNG guarantees; it
-- only makes accidental salt reuse across password creations unlikely.
local function generateSalt(context)
    saltCounter = saltCounter + 1

    local epoch = type(os.epoch) == "function" and os.epoch("utc") or 0
    local computerID = type(os.getComputerID) == "function" and
        os.getComputerID() or 0
    local clock = type(os.clock) == "function" and os.clock() or 0
    local randomPart = type(math.random) == "function" and math.random() or 0
    local material = table.concat({
        tostring(context or ""),
        tostring(epoch),
        tostring(computerID),
        tostring(clock),
        tostring(saltCounter),
        tostring(randomPart),
    }, ":")

    return string.sub(sha256Raw(material), 1, password.saltBytes)
end

-- The optional explicit iteration value supports published-vector tests and
-- future controlled migrations. Production callers omit it and receive the
-- central 4096-iteration cost. That cost is deliberately non-trivial for a
-- pure-Lua Advanced Computer, but is not equivalent to native Argon2/bcrypt
-- memory hardness and still requires the documented Minecraft timing check.
function password.createVerifier(plainPassword, saltContext, iterations)
    local passwordIsValid, validationError =
        password.validatePassword(plainPassword)

    if not passwordIsValid then
        return nil, validationError
    end

    local selectedIterations = iterations or password.defaultIterations

    if type(selectedIterations) ~= "number" or
        selectedIterations ~= math.floor(selectedIterations) or
        selectedIterations < password.minimumIterations or
        selectedIterations > password.maximumIterations then
        return nil, "Password verifier iteration count is outside policy."
    end

    local saltBytes = generateSalt(saltContext)
    local digestBytes = pbkdf2Raw(
        plainPassword,
        saltBytes,
        selectedIterations,
        password.derivedKeyBytes
    )

    return {
        algorithm = password.algorithm,
        iterations = selectedIterations,
        salt = bytesToHex(saltBytes),
        digest = bytesToHex(digestBytes),
    }, nil
end

-- Comparing every byte prevents an early mismatch position from directly
-- selecting a shorter loop. Lua, its garbage collector, and the CC:T VM cannot
-- provide a hard constant-time guarantee, so this is accurately described as
-- best effort rather than a side-channel-proof primitive.
local function constantTimeHexEquals(left, right)
    local difference = bxor(#left, #right)
    local maximumLength = math.max(#left, #right)

    for index = 1, maximumLength do
        difference = bor(
            difference,
            bxor(string.byte(left, index) or 0, string.byte(right, index) or 0)
        )
    end

    return difference == 0
end


function password.verify(plainPassword, verifier)
    local verifierIsValid, verifierError =
        password.validateVerifier(verifier)

    if not verifierIsValid then
        return false, verifierError
    end

    local passwordIsValid = password.validatePassword(plainPassword)

    if not passwordIsValid then
        return false, nil
    end

    local saltBytes = hexToBytes(verifier.salt)
    local candidate = bytesToHex(pbkdf2Raw(
        plainPassword,
        saltBytes,
        verifier.iterations,
        password.derivedKeyBytes
    ))

    return constantTimeHexEquals(candidate, verifier.digest), nil
end

return password
